-- tests/helpers.lua  —  shared fixtures and ngx/redis stubs for unit tests.
--
-- busted runs in plain Lua, not OpenResty, so we provide a minimal `ngx`
-- shim that lets pure-Lua modules (errors, log, sse, metrics) exercise
-- their happy paths without standing up nginx.

local M = {}

-- The real lua-resty-redis / lua-resty-http modules touch ngx.socket.tcp
-- at module load, which can't be satisfied under plain Lua. Production
-- modules `require` them at the top of the file, so we preload no-op
-- stand-ins. Tests monkey-patch around the actual network calls, so a
-- stub that returns a chainable truthy is sufficient.
local function fake_resty_module()
    return {
        new = function()
            return setmetatable({}, {
                __index = function() return function() return true end end,
            })
        end,
    }
end
package.preload["resty.redis"] = fake_resty_module
package.preload["resty.http"]  = fake_resty_module

-- tools/mcp.lua requires ngx.semaphore at module load (the per-server pipe
-- lock). A no-op semaphore (wait/post always succeed) is enough for tests
-- that don't model contention.
package.preload["ngx.semaphore"] = function()
    return {
        new = function()
            local s = {}
            function s:wait() return true end
            function s:post() return true end
            return s
        end,
    }
end

-- Fake ngx.pipe so mcp.bring_up can spawn a "server" and complete the
-- initialize / tools/list handshake without a real subprocess. The proc
-- queues a canned response per JSON-RPC request id (matching call_and_wait's
-- read-until-id loop) and advertises a single `echo` tool.
package.preload["ngx.pipe"] = function()
    local cj = require("cjson.safe")
    return {
        spawn = function()
            local pending = {}
            local proc = {}
            function proc:set_timeouts() end
            function proc:shutdown() end
            function proc:kill() end
            function proc:pid() return 4242 end
            function proc:write(data)
                local raw = type(data) == "table" and table.concat(data) or tostring(data)
                for line in raw:gmatch("[^\n]+") do
                    local msg = cj.decode(line)
                    if type(msg) == "table" and msg.id ~= nil then
                        local result
                        if msg.method == "initialize" then
                            result = { protocolVersion = "2024-11-05", serverInfo = { name = "fake" } }
                        elseif msg.method == "tools/list" then
                            result = { tools = { {
                                name = "echo", description = "echoes",
                                inputSchema = { type = "object" },
                            } } }
                        elseif msg.method == "tools/call" then
                            result = { content = { { type = "text", text = "ok" } } }
                        end
                        if result then
                            pending[#pending + 1] =
                                cj.encode({ jsonrpc = "2.0", id = msg.id, result = result })
                        end
                    end
                end
                return true
            end
            function proc:stdout_read_line()
                if #pending == 0 then return nil, "timeout" end
                return table.remove(pending, 1)
            end
            function proc:stderr_read_line() return nil, "timeout" end
            return proc
        end,
    }
end

-- Minimal ngx surface used by the modules we ship. Add fields lazily as
-- new tests need them.
function M.install_ngx_stub()
    local captured = {
        out      = {},
        log      = {},
        status   = 200,
        headers  = {},
        exited   = false,
    }

    local ngx_stub = {
        DEBUG = 1, INFO = 2, WARN = 3, ERR = 4,
        HTTP_OK = 200,

        now      = function() return 1.0 end,
        time     = function() return 1 end,
        sleep    = function() end,
        null     = setmetatable({}, { __tostring = function() return "null" end }),

        say      = function(s) table.insert(captured.out, tostring(s) .. "\n") end,
        print    = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            table.insert(captured.out, table.concat(parts))
        end,
        flush    = function() end,
        exit     = function(_) captured.exited = true end,

        log      = function(level, ...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            table.insert(captured.log, { level = level, msg = table.concat(parts) })
        end,

        header   = setmetatable({}, {
            __index    = function(_, k) return captured.headers[k] end,
            __newindex = function(_, k, v) captured.headers[k] = v end,
        }),

        status   = 200,
        headers_sent = false,

        ctx      = {},

        var      = {},
        req      = {
            get_method = function() return "GET" end,
            get_headers = function() return {} end,
            read_body  = function() end,
            get_body_data = function() return "" end,
        },

        -- Non-executing ngx.timer stub. Real timers fire deferred work
        -- (MCP bring-up, supervisor sweeps) in a phase where cosockets are
        -- allowed; under busted we just record that scheduling succeeded so
        -- module code takes the "timer available" branch without spawning
        -- subprocesses. Tests drive the deferred functions directly.
        timer    = {
            at    = function() return true end,
            every = function() return true end,
        },

        -- Synchronous stand-in for ngx.thread so the dispatcher's
        -- concurrent path is exercised without OpenResty. We capture the
        -- function + args at spawn time and run them on wait.
        thread   = {
            spawn = function(fn, ...)
                local args = { n = select("#", ...), ... }
                return { _fn = fn, _args = args }
            end,
            wait  = function(th)
                local results = { pcall(th._fn, table.unpack(th._args, 1, th._args.n)) }
                if results[1] then
                    return true, results[2]
                end
                return false, results[2]
            end,
        },
    }

    -- nginx exposes status as a property; tests can read it back via captured.
    setmetatable(ngx_stub, { __index = function(_, k)
        if k == "status" then return captured.status end
    end, __newindex = function(_, k, v)
        if k == "status" then captured.status = v else rawset(ngx_stub, k, v) end
    end })

    _G.ngx = ngx_stub
    return captured
end

function M.uninstall_ngx_stub()
    _G.ngx = nil
end

return M
