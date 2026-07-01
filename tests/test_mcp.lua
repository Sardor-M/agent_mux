-- tests/test_mcp.lua  —  MCP supervisor: backoff, manifest projection, the
-- respawn-scoping regression, spec seeding, and status.
--
-- We cannot stand up real subprocesses under busted (no OpenResty / ngx.pipe),
-- so these tests exercise the pure logic and the code paths that don't require
-- a live pipe: the backoff curve, the tool-call closure's dead-server branch
-- (which must reach respawn_if_due, not a nil global), spec seeding via
-- load_manifest, and status projection.

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

    it("backoff grows then caps at 30s", function()
        assert.equals(100, mcp._backoff_ms(0))          -- 2^0 * 100
        assert.equals(200, mcp._backoff_ms(1))          -- 2^1 * 100
        assert.equals(400, mcp._backoff_ms(2))
        -- The exponent is clamped at 8, so the effective ceiling is
        -- 2^8 * 100 = 25600ms; the outer min(30000, ...) never binds.
        assert.equals(25600, mcp._backoff_ms(8))
        assert.equals(25600, mcp._backoff_ms(50))       -- exponent clamp holds
        -- Monotonic non-decreasing.
        local prev = 0
        for a = 0, 12 do
            local b = mcp._backoff_ms(a)
            assert.is_true(b >= prev)
            prev = b
        end
    end)

    -- Regression for the scoping bug: the tool-call closure calls
    -- respawn_if_due when the subprocess is dead. Before the fix that was a
    -- nil global and threw "attempt to call a nil value". After the fix it
    -- is an upvalue, so a dead server under backoff returns a typed error
    -- instead of raising.
    it("dead-server tool call reaches respawn_if_due without a nil-global crash", function()
        local servers = mcp._servers()
        -- Seed a dead entry (proc=nil) with a high attempt count and a fresh
        -- last_attempt so respawn_if_due is backoff-blocked and returns
        -- without trying to spawn (which would need a real pipe).
        servers["demo"] = {
            spec            = { name = "demo", command = "false" },
            proc            = nil,
            attempts        = 8,
            restarts        = 0,
            last_attempt_ms = ngx.now() * 1000,
        }

        local manifest = mcp._make_tool_manifest(
            { name = "demo" }, { name = "echo" }, nil)
        assert.equals("echo", manifest.name)

        local ok, out = pcall(manifest.run, {}, {})
        assert.is_true(ok)                              -- no nil-global crash
        assert.is_true(out.is_error)
        assert.is_truthy(out.content:find("mcp_server_dead"))
        assert.is_truthy(out.content:find("backoff"))
    end)

    it("returns 'not running' when no entry exists for the server", function()
        local manifest = mcp._make_tool_manifest(
            { name = "ghost" }, { name = "noop" }, nil)
        local ok, out = pcall(manifest.run, {}, {})
        assert.is_true(ok)
        assert.is_true(out.is_error)
        assert.is_truthy(out.content:find("not running"))
    end)

    it("prefixes tool names when tool_prefix is set", function()
        local manifest = mcp._make_tool_manifest(
            { name = "demo" }, { name = "echo" }, "demo")
        assert.equals("demo.echo", manifest.name)
        assert.equals("mcp", manifest._origin)
        assert.equals("demo", manifest._mcp_server)
        assert.equals("echo", manifest._mcp_tool)
    end)

    it("load_manifest seeds specs so the supervisor can retry", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"servers":[{"name":"a","command":"x"},{"name":"b","command":"y"}]}')
        fh:close()

        local names, err = mcp.load_manifest(tmp)
        os.remove(tmp)

        assert.is_nil(err)
        assert.equals(2, #names)
        local servers = mcp._servers()
        assert.is_table(servers["a"])
        assert.equals("x", servers["a"].spec.command)
        assert.is_table(servers["b"])
    end)

    it("load_manifest skips entries missing name/command", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"servers":[{"name":"ok","command":"x"},{"name":"bad"}]}')
        fh:close()

        local names = mcp.load_manifest(tmp)
        os.remove(tmp)

        assert.equals(1, #names)
        assert.equals("ok", names[1])
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

    it("status projects per-server fields", function()
        local servers = mcp._servers()
        servers["demo"] = {
            spec         = { name = "demo", command = "python3" },
            proc         = nil,
            attempts     = 2,
            restarts     = 3,
            tools        = { "demo.echo", "demo.get_time" },
            in_flight    = 1,
            calls_total  = 42,
            errors_total = 5,
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
