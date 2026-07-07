-- tests/test_mcp.lua  —  MCP supervisor: backoff, manifest projection, bring-up
-- + registration, single-request servicing, queue enqueue, and status.
--
-- The owner light-thread (manager) can't be exercised under busted (no real
-- ngx.timer / semaphore scheduling), so we test its pieces directly:
--   * bring_up      — spawn handshake + tool registration (fake ngx.pipe)
--   * service_one   — one queued round-trip (the manager's inner step)
--   * run()         — enqueues onto the server queue
-- The end-to-end persistent-owner behaviour is verified by a live boot.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers  = require("tests.helpers")
local jsonrpc  = require("agent_mux.transport.jsonrpc")
local sema     = require("ngx.semaphore")

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
        assert.equals(25600, mcp._backoff_ms(8))
        assert.equals(25600, mcp._backoff_ms(50))
        local prev = 0
        for a = 0, 12 do
            local b = mcp._backoff_ms(a)
            assert.is_true(b >= prev)
            prev = b
        end
    end)

    it("make_tool_manifest prefixes names and sets origin fields", function()
        local m = mcp._make_tool_manifest({ name = "demo" }, { name = "echo" }, "demo")
        assert.equals("demo.echo", m.name)
        assert.equals("mcp", m._origin)
        assert.equals("demo", m._mcp_server)
        assert.equals("echo", m._mcp_tool)
    end)

    it("run returns 'not configured' when the server has no entry", function()
        local m = mcp._make_tool_manifest({ name = "ghost" }, { name = "noop" }, nil)
        local ok, out = pcall(m.run, {}, {})
        assert.is_true(ok)
        assert.is_true(out.is_error)
        assert.is_truthy(out.content:find("not configured"))
    end)

    it("run enqueues a request onto the server's queue", function()
        local e = mcp._seed_entry({ name = "t", command = "fake" })
        local m = mcp._make_tool_manifest({ name = "t" }, { name = "echo" }, "t")
        -- With the stub semaphore, done:wait returns immediately and no manager
        -- services the queue, so run reports no result — but the request is
        -- left enqueued for the (real) manager to pick up.
        local out = m.run({}, {})
        assert.equals(1, #e.queue)
        assert.is_true(out.is_error)
        assert.is_truthy(out.content:find("no_result"))
    end)

    it("bring_up spawns, handshakes, and registers tools", function()
        mcp._seed_entry({ name = "t", command = "fake", tool_prefix = "t" })
        local registered, err = mcp._bring_up({ name = "t", command = "fake", tool_prefix = "t" })
        assert.is_nil(err)
        assert.same({ "t.echo" }, registered)
        assert.is_table(registry.get("t.echo"))
        local e = mcp._servers()["t"]
        assert.is_true(e.alive)
        assert.same({ "t.echo" }, e.tools)
    end)

    it("service_one round-trips a queued request to the subprocess", function()
        mcp._seed_entry({ name = "t", command = "fake" })
        mcp._bring_up({ name = "t", command = "fake" })
        local e = mcp._servers()["t"]

        local reqobj = {
            req  = jsonrpc.request("tools/call", { name = "echo", arguments = {} }),
            done = sema.new(0),
        }
        e.queue[#e.queue + 1] = reqobj

        local serviced = mcp._service_one(e)
        assert.is_true(serviced)
        assert.is_nil(reqobj.err)
        assert.is_table(reqobj.result)
        assert.equals("ok", reqobj.result.content[1].text)
        assert.equals(1, e.calls_total)
        assert.equals(0, e.errors_total)
    end)

    it("service_one fails a request when the server is down and backoff-blocked", function()
        local e = mcp._seed_entry({ name = "t", command = "false" })
        e.proc, e.alive = nil, false
        e.attempts, e.last_attempt_ms = 8, ngx.now() * 1000   -- backoff not elapsed

        local reqobj = {
            req  = jsonrpc.request("tools/call", { name = "echo", arguments = {} }),
            done = sema.new(0),
        }
        e.queue[#e.queue + 1] = reqobj

        assert.is_true(mcp._service_one(e))
        assert.equals("server down", reqobj.err)
        assert.is_nil(reqobj.result)
    end)

    it("load_manifest seeds servers (with queue) and returns their names", function()
        local tmp = os.tmpname()
        local fh = io.open(tmp, "w")
        fh:write('{"servers":[{"name":"a","command":"x"},{"name":"b","command":"y"}]}')
        fh:close()

        local names, err = mcp.load_manifest(tmp)
        os.remove(tmp)

        assert.is_nil(err)
        assert.same({ "a", "b" }, names)
        local s = mcp._servers()
        assert.is_table(s["a"]); assert.is_table(s["a"].queue)
        assert.is_table(s["b"])
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
        assert.is_false(s.alive)
        assert.equals(3, s.restarts)
        assert.equals(2, s.tool_count)
        assert.equals(1, s.in_flight)
        assert.equals(42, s.calls_total)
        assert.equals(5, s.errors_total)
        assert.equals(12.5, s.last_latency_ms)
    end)
end)
