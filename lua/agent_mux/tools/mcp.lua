-- tools/mcp.lua  —  Model Context Protocol client (stdio transport) + supervisor.
--
-- Spawns each configured MCP server as a subprocess via `ngx.pipe`, performs
-- the JSON-RPC 2.0 initialize handshake, calls `tools/list` to discover tools,
-- and registers each one in the local registry.
--
-- ## Ownership model (why the "manager" light-thread exists)
--
-- ngx.pipe binds a spawned subprocess to the light-thread that created it: when
-- that request/timer callback returns, OpenResty reaps the child (the proc
-- cdata even has a `__gc` finalizer that kills it). So a subprocess spawned in
-- a transient timer or request handler dies the instant that context ends —
-- storing the handle in a module table does NOT keep it alive. (That was the
-- flapping-RESTARTS bug: every sweep respawned the server, and it died again
-- the moment the sweep callback returned.)
--
-- The fix: each server gets ONE persistent "manager" light-thread (a timer
-- callback that loops for the worker's lifetime). The manager spawns and *owns*
-- the subprocess and is the only code that touches the pipe. Tool-call handlers
-- never spawn or read the pipe; they push a request onto the server's queue,
-- signal the manager via a semaphore, and await the reply on a per-request
-- semaphore. Because the manager never returns, the subprocess is never reaped,
-- and because the manager services one request at a time, pipe access is
-- naturally serialised.
--
-- stdio only, newline-delimited JSON framing.
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

-- One entry per MCP server, keyed by name. Entry shape:
--   { spec, proc, info, alive, ever_up,
--     attempts, last_attempt_ms, restarts,
--     queue = {reqobj...}, work = semaphore, manager_started,
--     tools = {names}, in_flight, calls_total, errors_total, last_latency_ms }
-- A reqobj is { req = <jsonrpc>, result, err, done = semaphore }.
local _servers = {}

local DEFAULT_TIMEOUT_MS = 5000
-- How long the manager blocks waiting for work before an idle tick (during
-- which it proactively (re)spawns a dead server).
local IDLE_TICK_S = 5

-- Exponential backoff on respawn — the exponent is clamped at 8, so the
-- effective ceiling is 2^8 * 100 = 25600ms; the outer min(30000, …) never
-- binds. Keeps a permanently broken server from hammering the host.
local function backoff_ms(attempts)
    return math.min(30000, (2 ^ math.min(attempts, 8)) * 100)
end

-- A server is usable if we hold a proc and haven't marked it dead. We do NOT
-- poll proc:pid() for liveness — ngx.pipe's pid() is a static getter that
-- returns the spawn-time pid forever. Death is surfaced by a write/read error
-- on the pipe or a stderr EOF, which flips entry.alive = false.
local function is_alive(entry)
    if not entry or not entry.proc then return false end
    return entry.alive ~= false
end

-- Drain a server's stderr in its own light-thread so the child can't wedge on a
-- full stderr buffer, and so we detect death (stderr EOF) even between calls.
-- Does not own the proc (the manager does), so this thread ending never reaps
-- the child.
local function start_stderr_drainer(server_name, proc)
    local ok, terr = ngx.timer.at(0, function(premature)
        if premature then return end
        while true do
            if ngx.worker and ngx.worker.exiting and ngx.worker.exiting() then return end
            local cur = _servers[server_name]
            if not cur or cur.proc ~= proc then return end  -- superseded by a respawn

            local line, rerr = proc:stderr_read_line()
            if line then
                ngx.log(ngx.INFO, "mcp[", server_name, "] stderr: ", line)
            elseif rerr == "timeout" then
                -- nothing within the read timeout; loop and re-check state
            else
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
    -- ngx.pipe's proc method is `write` (lualib/ngx/pipe.lua); the array form
    -- avoids a concat. There is no `stdin_write`.
    local ok, err = proc:write({ body, "\n" })
    if not ok then return false, err end
    return true
end

-- Round-trip a request: write, then read replies until the id matches.
-- Interleaved server notifications are discarded for v0.1.
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
    end
end

-- Build the tool manifest the dispatcher registers. The run closure does NOT
-- touch the pipe — it hands the call to the server's manager and awaits it.
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
                return { is_error = true, content = "mcp server not configured: " .. server.name }
            end

            local reqobj = {
                req  = jsonrpc.request("tools/call", {
                    name = mcp_tool.name, arguments = input or {},
                }),
                done = semaphore.new(0),
            }

            entry.in_flight = (entry.in_flight or 0) + 1
            entry.queue[#entry.queue + 1] = reqobj
            entry.work:post()

            -- Wait a hair longer than the per-call timeout so the manager's own
            -- pipe timeout fires first and gives us a specific error.
            local wait_s = ((server.timeout_ms or DEFAULT_TIMEOUT_MS) / 1000) + 1
            local ok = reqobj.done:wait(wait_s)
            entry.in_flight = math.max(0, (entry.in_flight or 1) - 1)

            if not ok then
                return { is_error = true, content = "mcp_timeout: " .. server.name }
            end
            if reqobj.err then
                return { is_error = true, content = "mcp_call_failed: " .. tostring(reqobj.err) }
            end
            local result = reqobj.result
            if type(result) ~= "table" then
                return { is_error = true, content = "mcp_no_result: " .. server.name }
            end

            -- MCP { content=[{type="text",text=...}], isError } → our shape.
            local pieces = {}
            for _, blk in ipairs(result.content or {}) do
                if blk.type == "text" and blk.text then
                    pieces[#pieces + 1] = blk.text
                end
            end
            return {
                content  = table.concat(pieces, "\n"),
                is_error = result.isError and true or nil,
            }
        end,
    }
end

-- Spawn one server, run the initialize + tools/list handshake, register tools.
-- MUST be called from the server's manager light-thread so the proc it spawns
-- lives for the worker's lifetime. Mutates the pre-seeded entry (preserving its
-- queue / work semaphore / counters) rather than replacing it.
local function bring_up(server)
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

    local init_res, ierr = call_and_wait(proc, jsonrpc.request("initialize", {
        protocolVersion = "2024-11-05",
        capabilities    = {},
        clientInfo      = { name = "agent_mux", version = "0.3.0-dev" },
    }))
    if not init_res then
        proc:shutdown("stdin")
        return nil, "initialize: " .. tostring(ierr)
    end

    write_message(proc, jsonrpc.notification("notifications/initialized"))

    local list_res, lerr = call_and_wait(proc, jsonrpc.request("tools/list"))
    if not list_res then
        proc:shutdown("stdin")
        return nil, "tools/list: " .. tostring(lerr)
    end

    local entry = _servers[server.name]
    entry.proc  = proc
    entry.info  = init_res
    entry.spec  = server
    entry.alive = true

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
    entry.tools = registered

    start_stderr_drainer(server.name, proc)
    return registered
end

-- (Re)spawn a dead server if its backoff window has elapsed. Returns true when
-- the server is up afterwards. Called only from the manager light-thread.
local function ensure_up(entry)
    if is_alive(entry) then return true end

    local name    = entry.spec and entry.spec.name or "?"
    local now_ms  = ngx.now() * 1000
    local since   = now_ms - (entry.last_attempt_ms or 0)
    local wait_ms = backoff_ms(entry.attempts or 0)
    if since < wait_ms then return false end

    entry.attempts = (entry.attempts or 0) + 1
    entry.last_attempt_ms = now_ms

    if entry.proc then
        pcall(entry.proc.kill, entry.proc, 9)  -- reap a wedged predecessor
        entry.proc = nil
    end

    local was_up = entry.ever_up
    ngx.log(ngx.WARN, "mcp: ", was_up and "respawning " or "starting ", name,
                      " (attempt ", entry.attempts, ")")
    local registered, err = bring_up(entry.spec)
    if not registered then
        ngx.log(ngx.WARN, "mcp bring-up failed for ", name, ": ", tostring(err))
        return false
    end

    entry.attempts = 0
    entry.ever_up  = true
    if was_up then entry.restarts = (entry.restarts or 0) + 1 end
    ngx.log(ngx.INFO, "mcp: ", name, " up (", #registered, " tools)")
    return true
end

-- Service exactly one queued request. Returns true if it dequeued one. Kept
-- separate from the manager loop so unit tests can drive it synchronously.
local function service_one(entry)
    local reqobj = table.remove(entry.queue, 1)
    if not reqobj then return false end

    if not is_alive(entry) then ensure_up(entry) end
    if not is_alive(entry) then
        reqobj.err = "server down"
        reqobj.done:post()
        return true
    end

    local t0 = ngx.now() * 1000
    local ok, result, err = pcall(call_and_wait, entry.proc, reqobj.req)
    entry.last_latency_ms = ngx.now() * 1000 - t0
    entry.calls_total = (entry.calls_total or 0) + 1

    if not ok then
        entry.alive = false
        entry.errors_total = (entry.errors_total or 0) + 1
        reqobj.err = "crashed: " .. tostring(result)
    elseif not result then
        -- Only pipe-level failures (write:/read:) mean the server is gone;
        -- JSON-RPC protocol errors are valid replies from a healthy server.
        if err and (err:sub(1, 6) == "write:" or err:sub(1, 5) == "read:") then
            entry.alive = false
        end
        entry.errors_total = (entry.errors_total or 0) + 1
        reqobj.err = err
    else
        if result.isError then entry.errors_total = (entry.errors_total or 0) + 1 end
        reqobj.result = result
    end
    reqobj.done:post()
    return true
end

-- The persistent owner. Spawns + holds the subprocess and services its queue
-- for the worker's lifetime. Never returns until the worker is exiting, which
-- is exactly what keeps the child from being reaped.
local function manager_loop(premature, name)
    if premature then return end
    local entry = _servers[name]
    if not entry then return end

    ensure_up(entry)  -- initial spawn
    while true do
        if ngx.worker and ngx.worker.exiting and ngx.worker.exiting() then return end
        local got = entry.work:wait(IDLE_TICK_S)
        if got then
            local sok, serr = pcall(service_one, entry)
            if not sok then ngx.log(ngx.ERR, "mcp manager ", name, " service error: ", serr) end
        elseif not is_alive(entry) then
            ensure_up(entry)  -- idle-tick proactive recovery
        end
    end
end

-- Start a server's manager once. In unit tests (no ngx.timer) this no-ops and
-- tests drive bring_up / service_one directly.
local function start_manager(name)
    local entry = _servers[name]
    if not entry or entry.manager_started then return end
    if not (ngx and ngx.timer and ngx.timer.at) then return end
    entry.manager_started = true
    local ok, err = ngx.timer.at(0, manager_loop, name)
    if not ok then
        entry.manager_started = false
        ngx.log(ngx.WARN, "mcp: could not start manager for ", name, ": ", err)
    end
end

-- Seed an entry (queue + work semaphore + counters) for a server spec.
local function seed_entry(server)
    local e = _servers[server.name]
    if e then
        e.spec = server
        e.queue = e.queue or {}
        e.work  = e.work or semaphore.new(0)
        return e
    end
    _servers[server.name] = {
        spec            = server,
        alive           = false,
        ever_up         = false,
        attempts        = 0,
        last_attempt_ms = 0,
        restarts        = 0,
        queue           = {},
        work            = semaphore.new(0),
        manager_started = false,
        tools           = {},
        in_flight       = 0,
        calls_total     = 0,
        errors_total    = 0,
    }
    return _servers[server.name]
end

-- Read the manifest, seed each server, and start its manager. Called from
-- registry.bootstrap_mcp inside an ngx.timer (init.lua). Bring-up itself is
-- done by each manager, so this returns before tools are registered.
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

    local names = {}
    for _, server in ipairs(servers) do
        if not server.name or not server.command then
            ngx.log(ngx.WARN, "mcp server entry missing name/command — skipped")
        else
            seed_entry(server)
            start_manager(server.name)
            names[#names + 1] = server.name
        end
    end
    return names
end

-- Point-in-time status of every supervised server. Consumed by
-- GET /v1/mcp/servers and the CLI status view.
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
_M._seed_entry         = seed_entry
_M._bring_up           = bring_up
_M._service_one        = service_one

function _M._reset_for_test()
    for _, e in pairs(_servers) do
        if e.proc then pcall(function() e.proc:shutdown("stdin") end) end
    end
    _servers = {}
end

return _M
