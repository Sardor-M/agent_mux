-- tools/mcp.lua  —  Model Context Protocol client (stdio transport).
--
-- Spawns each configured MCP server as a subprocess via `ngx.pipe`,
-- performs the JSON-RPC 2.0 initialize handshake, calls `tools/list`
-- to discover tools, and registers each one in the local registry with
-- a `run` closure that sends `tools/call` over the pipe.
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

local cjson    = require("cjson.safe")
local jsonrpc  = require("agent_mux.transport.jsonrpc")
local registry = require("agent_mux.tools.registry")

local _M = {}

-- One process per MCP server, alive for the lifetime of the worker.
-- Keyed by server name so we can re-use the connection across
-- many tools/call invocations.
local _servers = {}

local DEFAULT_TIMEOUT_MS = 5000

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
    local ok, err = proc:stdin_write(body .. "\n")
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

            local req = jsonrpc.request("tools/call", {
                name      = mcp_tool.name,
                arguments = input or {},
            })

            local result, err = call_and_wait(entry.proc, req)
            if not result then
                return { is_error = true, content = "mcp_call_failed: " .. tostring(err) }
            end

            -- MCP returns { content = [{type="text", text="..."}], isError = bool }.
            -- Project to our { content = string, is_error? = true } shape.
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

-- Spawn one server, run initialize handshake + tools/list, register tools.
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

    _servers[server.name] = { proc = proc, info = init_res }

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

    return registered
end

-- Read and validate the config file, then bring up every server.
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
    return all_registered
end

-- Test / introspection helpers.
_M._servers = function() return _servers end

function _M._reset_for_test()
    for _, e in pairs(_servers) do
        if e.proc then e.proc:shutdown("stdin") end
    end
    _servers = {}
end

return _M
