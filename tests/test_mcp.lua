-- tests/test_mcp.lua  —  MCP supervisor: backoff, the respawn-scoping
-- regression, bring-up + registration, call instrumentation, and status.
--
-- The fake ngx.pipe / ngx.semaphore in tests/helpers.lua let bring_up
-- complete the initialize / tools/list handshake and register an `echo`
-- tool without a real subprocess. Liveness is the `entry.alive` flag (not
-- proc:pid()), matching the supervisor's source of truth.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")

describe("tools.mcp", function()
    local mcp, registry

    before_each(function()
        helpers.install_ngx_stub()
        mcp      = require("agent_mux.tools.mcp")
        registry = require("agent_mux.tools.registry")
        mcp._reset_for_test()
        registry._reset_for_test()
    end)

    after_each(function()
        mcp._reset_for_test()
        helpers.uninstall_ngx_stub()
    end)

    it("backoff grows then plateaus at the exponent clamp (25600ms)", function()
        assert.equals(100, mcp._backoff_ms(0))
        assert.equals(200, mcp._backoff_ms(1))
        assert.equals(400, mcp._backoff_ms(2))
        -- The exponent is clamped at 8, so the effective ceiling is
        -- 2^8 * 100 = 25600ms; the outer min(30000, ...) never binds.
        assert.equals(25600, mcp._backoff_ms(8))
        assert.equals(25600, mcp._backoff_ms(50))
        local prev = 0
        for a = 0, 12 do
            local b = mcp._backoff_ms(a)
            assert.is_true(b >= prev)
            prev = b
        end
    end)

    -- Regression for #7: the tool-call closure references respawn_if_due,
    -- declared later in the file. It must be captured as an upvalue, not a
    -- nil global. A dead server under backoff should return a typed error,
    -- not raise "attempt to call a nil value".
    it("dead-server tool call reaches respawn_if_due without a nil-global crash", function()
        local servers = mcp._servers()
        servers["demo"] = {
            spec = { name = "demo", command = "false" },
            proc = nil, alive = false,
            attempts = 8, last_attempt_ms = ngx.now() * 1000,
        }
        local manifest = mcp._make_tool_manifest({ name = "demo" }, { name = "echo" }, nil)
        local ok, out = pcall(manifest.run, {}, {})
        assert.is_true(ok)                               -- no nil-global crash
        assert.is_true(out.is_error)
        assert.is_truthy(out.content:find("mcp_server_dead"))
        assert.is_truthy(out.content:find("backoff"))
    end)

    it("returns 'not running' when no entry exists for the server", function()
        local manifest = mcp._make_tool_manifest({ name = "ghost" }, { name = "noop" }, nil)
        local ok, out = pcall(manifest.run, {}, {})
        assert.is_true(ok)
        assert.is_true(out.is_error)
        assert.is_truthy(out.content:find("not running"))
    end)

    it("prefixes tool names when tool_prefix is set", function()
        local manifest = mcp._make_tool_manifest({ name = "demo" }, { name = "echo" }, "demo")
        assert.equals("demo.echo", manifest.name)
        assert.equals("mcp", manifest._origin)
        assert.equals("demo", manifest._mcp_server)
        assert.equals("echo", manifest._mcp_tool)
    end)

    it("load_manifest brings up a server and registers its tools", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"servers":[{"name":"t","command":"fake","tool_prefix":"t"}]}')
        fh:close()

        local names, err = mcp.load_manifest(tmp)
        os.remove(tmp)

        assert.is_nil(err)
        assert.same({ "t.echo" }, names)
        assert.is_table(registry.get("t.echo"))
        local s = mcp._servers()["t"]
        assert.is_true(s.alive)
        assert.same({ "t.echo" }, s.tools)
    end)

    it("load_manifest skips entries missing name/command", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"servers":[{"name":"ok","command":"fake"},{"name":"bad"}]}')
        fh:close()

        mcp.load_manifest(tmp)
        os.remove(tmp)

        assert.is_table(mcp._servers()["ok"])
        assert.is_nil(mcp._servers()["bad"])
    end)

    it("load_manifest rejects a manifest with no servers array", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"nope":true}')
        fh:close()

        local names, err = mcp.load_manifest(tmp)
        os.remove(tmp)

        assert.is_nil(names)
        assert.is_truthy(err:find("servers"))
    end)

    it("a successful tool call updates the server's call counters", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"servers":[{"name":"t","command":"fake"}]}')
        fh:close()
        mcp.load_manifest(tmp)
        os.remove(tmp)

        local echo = registry.get("echo")
        assert.is_table(echo)
        local out = echo.run({}, {})
        assert.equals("ok", out.content)
        assert.is_nil(out.is_error)

        local s = mcp._servers()["t"]
        assert.equals(1, s.calls_total)
        assert.equals(0, s.errors_total)
        assert.equals(0, s.in_flight)
    end)

    it("status projects per-server fields", function()
        local servers = mcp._servers()
        servers["demo"] = {
            spec = { name = "demo", command = "python3" },
            proc = nil, alive = false,
            attempts = 2, restarts = 3,
            tools = { "demo.echo", "demo.get_time" },
            in_flight = 1, calls_total = 42, errors_total = 5,
            last_latency_ms = 12.5,
        }

        local st = mcp.status()
        assert.equals(1, #st)
        local s = st[1]
        assert.equals("demo", s.name)
        assert.is_false(s.alive)           -- proc is nil
        assert.equals("python3", s.command)
        assert.equals(3, s.restarts)
        assert.equals(2, s.tool_count)
        assert.equals(1, s.in_flight)
        assert.equals(42, s.calls_total)
        assert.equals(5, s.errors_total)
        assert.equals(12.5, s.last_latency_ms)
    end)
end)
