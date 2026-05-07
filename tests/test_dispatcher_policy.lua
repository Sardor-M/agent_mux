-- tests/test_dispatcher_policy.lua  —  dispatcher honours new policy modules.
--
-- Verifies: auth denial path, rate-limit denial path. Uses the
-- synchronous ngx.thread shim so we don't need OpenResty.
--
-- The Redis-backed rate-limit *script* requires Redis to actually run;
-- here we monkey-patch policy.ratelimit.try_consume so the dispatcher's
-- branch is exercised without that dependency.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local registry   = require("agent_mux.tools.registry")
local ratelimit  = require("agent_mux.policy.ratelimit")
local dispatcher = require("agent_mux.tools.dispatcher")

local function recording_sse()
    local events = {}
    return {
        emit = function(_, name, payload)
            events[#events + 1] = { name = name, payload = payload }
        end,
    }, events
end

local function session_with(policy)
    return { id = "sess_t", model = "m", tool_policy = policy }
end

local original_try_consume = ratelimit.try_consume

describe("dispatcher integration with policy", function()
    before_each(function()
        helpers.install_ngx_stub()
        registry._reset_for_test()
        registry.register({
            name = "ok", description = ".", schema = {},
            run  = function() return { content = "yes" } end,
        })
        ratelimit.try_consume = function(_, _, _) return true, 100, 0 end
    end)

    after_each(function() ratelimit.try_consume = original_try_consume end)

    it("denies tools blocked by deny list", function()
        local sse, events = recording_sse()
        local results = dispatcher.run_concurrent(
            session_with({ mode = "allow_all", deny = { "ok" } }),
            { { id = "u1", name = "ok", input = {} } }, sse)
        assert.is_true(results[1].is_error)
        assert.is_truthy(results[1].content:find("permission_denied"))
        assert.is_truthy(results[1].content:find("deny_list"))
    end)

    it("denies tools not in the allow list", function()
        local sse, _ = recording_sse()
        local results = dispatcher.run_concurrent(
            session_with({ mode = "list", allow = { "other" } }),
            { { id = "u1", name = "ok", input = {} } }, sse)
        assert.is_true(results[1].is_error)
        assert.is_truthy(results[1].content:find("not_in_allow_list"))
    end)

    it("denies when rate limit returns not-allowed", function()
        ratelimit.try_consume = function(_, _, _) return false, 0, 250 end
        local sse, events = recording_sse()
        local results = dispatcher.run_concurrent(
            session_with({ mode = "allow_all" }),
            { { id = "u1", name = "ok", input = {} } }, sse)
        assert.is_true(results[1].is_error)
        assert.is_truthy(results[1].content:find("rate_limited"))
        -- result event includes retry_after_ms
        local result_event
        for _, e in ipairs(events) do
            if e.name == "tool_result" then result_event = e end
        end
        assert.equals(250, result_event.payload.retry_after_ms)
    end)

    it("passes through to the handler when policy + rate limit allow", function()
        local sse, _ = recording_sse()
        local results = dispatcher.run_concurrent(
            session_with({ mode = "allow_all" }),
            { { id = "u1", name = "ok", input = {} } }, sse)
        assert.is_nil(results[1].is_error)
        assert.equals("yes", results[1].content)
    end)
end)

helpers.uninstall_ngx_stub()
