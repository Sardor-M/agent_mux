-- tests/test_dispatcher.lua  —  concurrent dispatch + result ordering.
--
-- Uses the synchronous ngx.thread shim from tests/helpers.lua so we
-- don't need OpenResty to exercise the parallel path; semantics match
-- (results returned in input order, errors contained, SSE events emitted).

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local registry   = require("agent_mux.tools.registry")
local dispatcher = require("agent_mux.tools.dispatcher")

-- A minimal SSE writer that just records emitted events.
local function recording_sse()
    local events = {}
    return {
        emit = function(_, name, payload)
            events[#events + 1] = { name = name, payload = payload }
        end,
    }, events
end

local function make_session()
    return { id = "sess_test", model = "mock-claude", tool_policy = nil }
end

describe("tools.dispatcher", function()
    before_each(function()
        helpers.install_ngx_stub()
        registry._reset_for_test()
    end)

    it("returns results in input order across concurrent threads", function()
        registry.register({
            name = "echo", description = "echoes", schema = {},
            run = function(input) return { content = input.text } end,
        })

        local sse, events = recording_sse()
        local uses = {
            { id = "u1", name = "echo", input = { text = "first"  } },
            { id = "u2", name = "echo", input = { text = "second" } },
            { id = "u3", name = "echo", input = { text = "third"  } },
        }
        local results = dispatcher.run_concurrent(make_session(), uses, sse)
        assert.equals(3, #results)
        assert.equals("u1",     results[1].tool_use_id)
        assert.equals("first",  results[1].content)
        assert.equals("u2",     results[2].tool_use_id)
        assert.equals("second", results[2].content)
        assert.equals("u3",     results[3].tool_use_id)
        assert.equals("third",  results[3].content)
        -- start, 3 calls, 3 results, complete = 8 events
        assert.equals(8, #events)
    end)

    it("synthesises an error result for unknown tools", function()
        local sse, _ = recording_sse()
        local results = dispatcher.run_concurrent(
            make_session(),
            { { id = "u1", name = "ghost", input = {} } },
            sse
        )
        assert.is_true(results[1].is_error)
        assert.is_truthy(results[1].content:find("not registered"))
    end)

    it("contains handler errors as is_error tool_results, not panics", function()
        registry.register({
            name = "boom", description = "explodes", schema = {},
            run  = function() error("kaboom") end,
        })

        local sse, _ = recording_sse()
        local results = dispatcher.run_concurrent(
            make_session(),
            { { id = "u1", name = "boom", input = {} } },
            sse
        )
        assert.equals(1, #results)
        assert.is_true(results[1].is_error)
        assert.is_truthy(results[1].content:find("handler_error"))
    end)

    it("respects tool_policy.allow whitelist", function()
        registry.register({
            name = "ok", description = ".", schema = {},
            run  = function() return { content = "yes" } end,
        })
        local session = make_session()
        session.tool_policy = { allow = { "other_tool" } }   -- "ok" not allowed

        local sse, _ = recording_sse()
        local results = dispatcher.run_concurrent(session,
            { { id = "u1", name = "ok", input = {} } }, sse)
        assert.is_true(results[1].is_error)
        assert.is_truthy(results[1].content:find("permission_denied"))
    end)

    it("counts errors in the dispatch_complete event", function()
        registry.register({
            name = "fail", description = ".", schema = {},
            run  = function() return { is_error = true, content = "no" } end,
        })

        local sse, events = recording_sse()
        dispatcher.run_concurrent(make_session(),
            { { id = "u1", name = "fail", input = {} } }, sse)
        local final = events[#events]
        assert.equals("tool_dispatch_complete", final.name)
        assert.equals(1, final.payload.errors)
    end)
end)

helpers.uninstall_ngx_stub()
