-- tests/test_smoke.lua — sanity check that every module loads with no syntax
-- errors and exposes the expected public surface. Cheap regression net.
--
-- Run with:  busted tests/test_smoke.lua

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

describe("smoke", function()
    local helpers = require("tests.helpers")

    before_each(function() helpers.install_ngx_stub() end)
    after_each(function()  helpers.uninstall_ngx_stub() end)

    it("loads agent_mux", function()
        local m = require("agent_mux")
        assert.is_string(m._VERSION)
        assert.equals("agent_mux", m._NAME)
    end)

    it("loads errors and respond exits cleanly", function()
        local errors = require("agent_mux.errors")
        errors.respond(404, "not_found", "no route")
        -- No exception means we wrote a body and called ngx.exit.
    end)

    it("loads log without raising", function()
        local log = require("agent_mux.observability.log")
        log.info("test_event", { foo = "bar" })
    end)

    it("loads metrics, registers and renders", function()
        local metrics = require("agent_mux.observability.metrics")
        metrics._reset_for_test()
        metrics.init()
        metrics.inc("agent_mux_sessions_total", { status = "started" })
        metrics.write()  -- writes to the ngx stub
    end)

    it("loads transport.sse and emits", function()
        local sse = require("agent_mux.transport.sse").new()
        sse:emit("hello", { world = 1 })
        sse:close()
    end)

    it("loads server module (stubs respond)", function()
        local server = require("agent_mux.server")
        assert.is_function(server.access)
        assert.is_function(server.content)
        assert.is_function(server.log_phase)
        assert.is_function(server.handle_session)
    end)

    it("loads agent_loop / session.store / tools.registry stubs", function()
        local loop  = require("agent_mux.agent_loop")
        local store = require("agent_mux.session.store")
        local reg   = require("agent_mux.tools.registry")
        assert.is_function(loop.new)
        assert.is_function(store.create)
        assert.is_function(reg.register)
        reg._reset_for_test()
        reg.register({
            name = "noop", description = "no-op", schema = {},
            run = function() end,
        })
        assert.is_table(reg.get("noop"))
    end)

    it("loads redis_client without connecting", function()
        local rc = require("agent_mux.redis_client")
        assert.is_function(rc.connect)
        assert.is_function(rc.run)
        rc._reset_for_test()
    end)
end)
