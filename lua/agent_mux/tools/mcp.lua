-- tools/mcp.lua  —  Model Context Protocol client (stdio transport) + supervisor.
--
-- Spawns each configured MCP server as a subprocess via `ngx.pipe`,
-- performs the JSON-RPC 2.0 initialize handshake, calls `tools/list`
-- to discover tools, and registers each one in the local registry with
-- a `run` closure that sends `tools/call` over the pipe.
--
-- Recovery is driven two ways: a background sweep (`ngx.timer.every`)
-- respawns dead servers proactively, and the tool-call path respawns lazily
-- on demand — whichever happens first. Death is surfaced by pipe/stderr
-- errors flipping `entry.alive`, not by polling pid.
--
-- For week 3 v0.1 we support **stdio only** with newline-delimited JSON
-- framing (the simpler MCP transport). The HTTP/SSE transport is a
-- stretch goal — the JSON-RPC layer is shared, so adding it is largely
-- swapping the read/write helpers.
--
-- Configuration shape (read from a JSON file at bootstrap):
--
--   {
--     "servers": [
--       {
--         "name": "demo",
--         "command": "python3",
--         "args": ["examples/tools/mcp_demo/server.py"],
--         "tool_prefix": "demo",        // optional; tools become `demo.<n>`
--         "timeout_ms": 5000             // optional
--       }
--     ]
--   }

local cjson     = require("cjson.safe")
local jsonrpc   = require("agent_mux.transport.jsonrpc")
local registry  = require("agent_mux.tools.registry")
local semaphore = require("ngx.semaphore")

local _M = {}

-- One process per MCP server, alive for the lifetime of the worker.
-- Keyed by server name so we can re-use the connection across
-- many tools/call invocations.
--
-- Each entry shape:
--   { proc, info, spec, attempts, last_attempt_ms, alive, sem,
--     restarts, tools, in_flight, calls_total, errors_total, last_latency_ms }
local _servers = {}
local _supervisor_started = false

local DEFAULT_TIMEOUT_MS   = 5000
local SUPERVISE_INTERVAL_S = 5     -- how often the supervisor sweeps for dead servers

-- Forward declarations — these are referenced by closures defined earlier
-- in the file than their `function` bodies. Without the `local` here, the
-- earlier references would compile to *global* lookups (always nil) and the
-- respawn path would crash with "attempt to call a nil value".
local respawn_if_due
local bring_up
local supervise

-- Exponential backoff on respawn — the exponent is clamped at 8, so the
-- effective ceiling is 2^8 * 100 = 25600ms; the outer min(30000, …) never
-- binds. Keeps a permanently broken server from hammering the host while
-- still retrying eventually.
local function backoff_ms(attempts)
    return math.min(30000, (2 ^ math.min(attempts, 8)) * 100)
end

-- Probe an MCP server's subprocess. Returns true if it's believed running
-- and usable, false if it has died or was never spawned.
--
-- We deliberately do NOT use proc:pid() for liveness: ngx.pipe's pid() is a
-- static getter that returns the spawn-time pid forever — it does not become
-- nil when the child exits. Death is instead surfaced as a write/read error
-- on the pipe (or stderr EOF), at which point the call path / stderr drainer
-- flips entry.alive = false. This flag is the source of truth.
local function is_alive(entry)
    if not entry or not entry.proc then return false end
    return entry.alive ~= false
end

-- Continuously drain a server's stderr so its pipe buffer can never fill.
-- A stdio MCP server that logs to stderr (the Python SDK does) would
-- otherwise block in write() once the ~64KB kernel buffer fills and stop
-- servicing stdin — a silent, unrecoverable wedge. We run this in a timer
-- (cosocket phase) and log each line. stderr EOF ("closed") is also our
-- cleanest death signal, so we flip entry.alive there.
local function start_stderr_drainer(server_name, proc)
    local ok, terr = ngx.timer.at(0, function(premature)
        if premature then return end
        while true do
            if ngx.worker and ngx.worker.exiting and ngx.worker.exiting() then return end
            local cur = _servers[server_name]
            -- If the server was respawned, `proc` is stale — this drainer
            -- belongs to the old process and should exit; the new process
            -- has its own drainer.
            if not cur or cur.proc ~= proc then return end

            local line, rerr = proc:stderr_read_line()
            if line then
                ngx.log(ngx.INFO, "mcp[", server_name, "] stderr: ", line)
            elseif rerr == "timeout" then
                -- No output within the read timeout — loop and re-check
                -- worker/respawn state.
            else
                -- "closed" / EOF / other error: the child's stderr is gone,
                -- which means the process is gone. Mark dead and stop.
                cur.alive = false
                ngx.log(ngx.WARN, "mcp[", server_name,
                    "] stderr closed (", tostring(rerr), ") — marking dead")
                return
            end
        end
    end)
    if not ok then
        ngx.log(ngx.WARN, "mcp[", server_name, "] could not start stderr drainer: ", terr)
    end
end

-- Read newline-delimited JSON. Returns nil on EOF / timeout.
local function read_message(proc)
    local line, err = proc:stdout_read_line()
    if not line then return nil, err end
    return jsonrpc.decode(line)
end

-- Write one JSON-RPC message followed by a newline.
local function write_message(proc, msg)
    local body = jsonrpc.encode(msg)
    if not body then return false, "encode failed" end
    -- ngx.pipe's proc method is `write` (see lualib/ngx/pipe.lua); there is no
    -- `stdin_write`, and calling it FFI-errors "struct has no member".
    local ok, err = proc:write(body .. "\n")
    if not ok then return false, err end
    return true
end

-- Round-trip a request: write, then read replies until we see one with
-- the matching id. (MCP servers can interleave server-initiated
-- notifications which we discard for v0.1.)
local function call_and_wait(proc, request)
    local ok, werr = write_message(proc, request)
    if not ok then return nil, "write: " .. tostring(werr) end

    while true do
        local msg, rerr = read_message(proc)
        if not msg then return nil, "read: " .. tostring(rerr) end
        if msg.id == request.id then
            if msg.error then
                return nil, ("rpc_error %d: %s"):format(
                    msg.error.code or 0, msg.error.message or "?")
            end
            return msg.result
        end
        -- Otherwise it's an unrelated notification or out-of-order
        -- response — ignore for v0.1. Real MCP clients buffer these.
    end
end

-- Build the tool manifest the dispatcher will register.
local function make_tool_manifest(server, mcp_tool, prefix)
    local local_name = prefix and (prefix .. "." .. mcp_tool.name) or mcp_tool.name

    return {
        name        = local_name,
        description = mcp_tool.description or ("MCP tool from " .. server.name),
        schema      = mcp_tool.inputSchema or { type = "object" },
        timeout_ms  = server.timeout_ms or DEFAULT_TIMEOUT_MS,
        _origin     = "mcp",
        _mcp_server = server.name,
        _mcp_tool   = mcp_tool.name,

        run = function(input, _ctx)
            local entry = _servers[server.name]
            if not entry then
                return { is_error = true, content = "mcp server not running: " .. server.name }
            end

            -- Detect dead proc and attempt respawn. If the respawn
            -- succeeds, the tool name we hold may have been re-registered
            -- against a fresh manifest — that's fine, our closure still
            -- finds the new entry on the next lookup.
            if not is_alive(entry) then
                local ok, rerr = respawn_if_due(server.name)
                if not ok then
                    entry.calls_total  = (entry.calls_total  or 0) + 1
                    entry.errors_total = (entry.errors_total or 0) + 1
                    return {
                        is_error = true,
                        content  = "mcp_server_dead: " .. server.name .. " — " .. tostring(rerr),
                    }
                end
                entry = _servers[server.name]
            end

            local req = jsonrpc.request("tools/call", {
                name      = mcp_tool.name,
                arguments = input or {},
            })

            -- Serialise pipe access: only one in-flight request per server,
            -- so concurrent tool calls can't interleave on the shared stdio
            -- pipe or steal each other's responses. Wait up to the tool's
            -- timeout for the lock.
            local timeout_s = (server.timeout_ms or DEFAULT_TIMEOUT_MS) / 1000
            local lock_ok, lock_err = entry.sem:wait(timeout_s)
            if not lock_ok then
                return {
                    is_error = true,
                    content  = "mcp_busy: " .. server.name .. " — " .. tostring(lock_err),
                }
            end

            -- Re-fetch entry under the lock: the server may have been
            -- respawned while we were waiting, giving us a fresh proc.
            -- Also re-check liveness — if it died while we waited but no
            -- respawn has run yet, fail fast rather than burning the timeout.
            entry = _servers[server.name] or entry
            if not is_alive(entry) then
                entry.sem:post()
                return {
                    is_error = true,
                    content  = "mcp_server_dead: " .. server.name
                               .. " (died while waiting for lock)",
                }
            end

            -- Wrap in pcall so sem:post() is guaranteed even if call_and_wait
            -- raises an unexpected Lua error (nil-deref, library throw, etc.).
            entry.in_flight = (entry.in_flight or 0) + 1
            local started_ms = ngx.now() * 1000
            local call_ok, result, call_err = pcall(call_and_wait, entry.proc, req)
            entry.sem:post()

            entry.in_flight     = math.max(0, (entry.in_flight or 1) - 1)
            entry.last_latency_ms = ngx.now() * 1000 - started_ms
            entry.calls_total   = (entry.calls_total or 0) + 1

            if not call_ok then
                -- result holds the error string thrown by the Lua runtime
                entry.alive = false
                entry.errors_total = (entry.errors_total or 0) + 1
                return { is_error = true, content = "mcp_call_crashed: " .. tostring(result) }
            elseif not result then
                -- Only pipe-level failures mean the server is gone.
                -- JSON-RPC protocol errors (bad params, unknown method, etc.)
                -- are valid responses from a healthy server and must NOT
                -- trigger a respawn — only "write:" / "read:" prefixes do.
                if call_err and (call_err:sub(1, 6) == "write:" or call_err:sub(1, 5) == "read:") then
                    entry.alive = false
                end
                entry.errors_total = (entry.errors_total or 0) + 1
                return { is_error = true, content = "mcp_call_failed: " .. tostring(call_err) }
            end

            -- MCP returns { content = [{type="text", text="..."}], isError = bool }.
            -- Project to our { content = string, is_error? = true } shape.
            local pieces = {}
            for _, blk in ipairs(result.content or {}) do
                if blk.type == "text" and blk.text then
                    pieces[#pieces + 1] = blk.text
                end
            end

            if result.isError then
                entry.errors_total = (entry.errors_total or 0) + 1
            end

            return {
                content  = table.concat(pieces, "\n"),
                is_error = result.isError and true or nil,
            }
        end,
    }
end

-- Spawn one server, run initialize handshake + tools/list, register tools.
function bring_up(server)
    local ngx_pipe = require("ngx.pipe")
    local cmd = { server.command }
    for _, a in ipairs(server.args or {}) do cmd[#cmd + 1] = a end

    local proc, err = ngx_pipe.spawn(cmd)
    if not proc then return nil, "spawn: " .. tostring(err) end
    proc:set_timeouts(
        server.timeout_ms or DEFAULT_TIMEOUT_MS,
        server.timeout_ms or DEFAULT_TIMEOUT_MS,
        server.timeout_ms or DEFAULT_TIMEOUT_MS
    )

    -- 1. initialize
    local init_req = jsonrpc.request("initialize", {
        protocolVersion = "2024-11-05",
        capabilities    = {},
        clientInfo      = { name = "agent_mux", version = "0.3.0-dev" },
    })
    local init_res, ierr = call_and_wait(proc, init_req)
    if not init_res then
        proc:shutdown("stdin")
        return nil, "initialize: " .. tostring(ierr)
    end

    -- 2. notifications/initialized (no response expected)
    write_message(proc, jsonrpc.notification("notifications/initialized"))

    -- 3. tools/list
    local list_req = jsonrpc.request("tools/list")
    local list_res, lerr = call_and_wait(proc, list_req)
    if not list_res then
        proc:shutdown("stdin")
        return nil, "tools/list: " .. tostring(lerr)
    end

    -- Preserve counters across respawns so backoff escalates and status
    -- totals survive a crash; reset attempts on the first successful
    -- registration after respawn (in respawn_if_due).
    -- The semaphore (1 resource) is the per-server pipe lock: it serialises
    -- concurrent tools/call round-trips so two light threads can't interleave
    -- writes/reads on the same stdio pipe. Preserved across respawns so a
    -- waiter blocked during a respawn still holds a valid lock afterward.
    local existing = _servers[server.name]
    _servers[server.name] = {
        proc            = proc,
        info            = init_res,
        spec            = server,
        attempts        = (existing and existing.attempts) or 0,
        last_attempt_ms = ngx.now() * 1000,
        alive           = true,
        sem             = (existing and existing.sem) or semaphore.new(1),
        restarts        = (existing and existing.restarts) or 0,
        tools           = {},
        in_flight       = 0,
        calls_total     = (existing and existing.calls_total) or 0,
        errors_total    = (existing and existing.errors_total) or 0,
        last_latency_ms = existing and existing.last_latency_ms,
    }

    -- Start draining stderr so the child can't deadlock on a full pipe.
    start_stderr_drainer(server.name, proc)

    -- 4. register every discovered tool
    local registered = {}
    for _, mcp_tool in ipairs(list_res.tools or {}) do
        local manifest = make_tool_manifest(server, mcp_tool, server.tool_prefix)
        local ok, rerr = pcall(registry.register, manifest)
        if ok then
            registered[#registered + 1] = manifest.name
        else
            ngx.log(ngx.WARN, "mcp register failed for ", manifest.name, ": ", rerr)
        end
    end
    _servers[server.name].tools = registered

    return registered
end

-- Try to respawn a dead MCP server. Honours backoff so a perpetually
-- broken process doesn't get hammered. Returns true on success.
function respawn_if_due(server_name)
    local entry = _servers[server_name]
    if not entry then return false, "no spec for " .. server_name end
    if not entry.spec then return false, "no spec for " .. server_name end
    if is_alive(entry) then return true end

    local now_ms      = ngx.now() * 1000
    local since_last  = now_ms - (entry.last_attempt_ms or 0)
    local needed_wait = backoff_ms(entry.attempts or 0)
    if since_last < needed_wait then
        return false, ("backoff: %dms remaining"):format(needed_wait - since_last)
    end

    entry.attempts = (entry.attempts or 0) + 1
    entry.last_attempt_ms = now_ms
    ngx.log(ngx.WARN, "mcp_server_died: respawning ", server_name,
                      " (attempt ", entry.attempts, ")")

    -- Kill the stale process before spawning a new one to prevent leaks.
    -- The proc may still be running if it was wedged/unresponsive rather
    -- than self-terminated; pcall guards against a kill() error on an
    -- already-dead handle.
    if entry.proc then
        pcall(entry.proc.kill, entry.proc, 9)
        entry.proc = nil
    end

    local registered, err = bring_up(entry.spec)
    if not registered then
        ngx.log(ngx.WARN, "mcp respawn failed for ", server_name, ": ", err)
        return false, err
    end

    -- Success — bump the cumulative restart counter and reset attempts so
    -- the next failure starts at full backoff window again rather than
    -- pinning at the cap.
    local live = _servers[server_name]
    if live then
        live.attempts = 0
        live.restarts = (live.restarts or 0) + 1
    end
    ngx.log(ngx.INFO, "mcp_server_respawned: ", server_name,
                      " (", #registered, " tools re-registered)")
    return true
end

-- Background sweep: respawn any server whose subprocess has died. Runs on a
-- timer so recovery does not depend on a tool call arriving; the stderr
-- drainer flips entry.alive on EOF, and this picks it up within one interval.
-- Backoff is enforced inside respawn_if_due, so a broken server is retried at
-- most once per its current backoff window.
function supervise()
    for name, entry in pairs(_servers) do
        if entry.spec and not is_alive(entry) then
            respawn_if_due(name)
        end
    end
end

-- Arm the supervisor timer once per worker. load_manifest runs in a timer
-- phase (see init.lua bootstrap_mcp), where ngx.timer.every is available; if
-- timers are unavailable (unit tests) we no-op and rely on lazy respawn.
local function start_supervisor()
    if _supervisor_started then return end
    if not (ngx and ngx.timer and ngx.timer.every) then return end
    local ok, err = ngx.timer.every(SUPERVISE_INTERVAL_S, function(premature)
        if premature then return end
        local sok, serr = pcall(supervise)
        if not sok then ngx.log(ngx.WARN, "mcp supervise sweep failed: ", serr) end
    end)
    if ok then
        _supervisor_started = true
        ngx.log(ngx.INFO, "mcp supervisor armed (every ", SUPERVISE_INTERVAL_S, "s)")
    else
        ngx.log(ngx.WARN, "mcp supervisor timer failed to start: ", err)
    end
end

-- Read and validate the config file, then bring up every server and arm the
-- supervisor. Called from registry.bootstrap_mcp inside an ngx.timer (init.lua),
-- where ngx.pipe cosocket I/O and ngx.timer.every are both permitted.
function _M.load_manifest(path)
    local f, ferr = io.open(path, "rb")
    if not f then return nil, "read " .. path .. ": " .. tostring(ferr) end
    local raw = f:read("*a")
    f:close()
    local doc, derr = cjson.decode(raw)
    if not doc then return nil, "decode " .. path .. ": " .. tostring(derr) end

    local servers = doc.servers
    if type(servers) ~= "table" then
        return nil, "manifest missing 'servers' array"
    end

    local all_registered = {}
    for _, server in ipairs(servers) do
        if not server.name or not server.command then
            ngx.log(ngx.WARN, "mcp server entry missing name/command — skipped")
        else
            -- Pre-seed a dead stub so the supervisor has a spec to retry even
            -- if bring_up fails on the first attempt. bring_up replaces this
            -- entry on success; on failure it remains with alive=false.
            if not _servers[server.name] then
                _servers[server.name] = {
                    spec            = server,
                    alive           = false,
                    attempts        = 0,
                    last_attempt_ms = 0,
                    sem             = semaphore.new(1),
                    restarts        = 0,
                    tools           = {},
                    in_flight       = 0,
                    calls_total     = 0,
                    errors_total    = 0,
                }
            else
                _servers[server.name].spec = server
            end
            local registered, err = bring_up(server)
            if not registered then
                ngx.log(ngx.WARN, "mcp server '", server.name, "' bring-up failed: ", err)
            else
                for _, n in ipairs(registered) do
                    all_registered[#all_registered + 1] = n
                end
            end
        end
    end

    start_supervisor()
    return all_registered
end

-- Point-in-time status of every supervised server. Consumed by the
-- GET /v1/mcp/servers endpoint and the CLI status view.
function _M.status()
    local out = {}
    for name, e in pairs(_servers) do
        local pid
        if e.proc then
            local ok, p = pcall(function() return e.proc:pid() end)
            if ok then pid = p end
        end
        out[#out + 1] = {
            name            = name,
            alive           = is_alive(e),
            pid             = pid,
            command         = e.spec and e.spec.command,
            restarts        = e.restarts or 0,
            attempts        = e.attempts or 0,
            tools           = e.tools or {},
            tool_count      = e.tools and #e.tools or 0,
            in_flight       = e.in_flight or 0,
            calls_total     = e.calls_total or 0,
            errors_total    = e.errors_total or 0,
            last_latency_ms = e.last_latency_ms,
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Test / introspection helpers.
_M._servers            = function() return _servers end
_M._backoff_ms         = backoff_ms
_M._is_alive           = is_alive
_M._make_tool_manifest = make_tool_manifest
_M._supervise          = function() return supervise() end

function _M._reset_for_test()
    for _, e in pairs(_servers) do
        if e.proc then pcall(function() e.proc:shutdown("stdin") end) end
    end
    _servers = {}
    _supervisor_started = false
end

return _M
