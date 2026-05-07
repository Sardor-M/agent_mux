-- tests/test_budget.lua  —  session/budget wrapper, monkey-patching the
-- Redis script call so this is a pure-Lua test.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local redis  = require("agent_mux.redis_client")
local budget = require("agent_mux.session.budget")

local function session_with(max)
    return { id = "sess_b", budget = { max_tokens = max } }
end

local original_run = redis.run

describe("session.budget", function()
    -- busted insulates describe blocks from file-top globals, so re-install
    -- the ngx stub for each test even though we already called it above.
    before_each(function() helpers.install_ngx_stub() end)
    after_each(function() redis.run = original_run end)

    it("passes through when no cap is configured", function()
        local s = { id = "sess_b" }   -- no .budget
        local ok, used, remaining = budget.try_consume(s, 100)
        assert.is_true(ok)
        assert.equals(0, used)
    end)

    it("calls the budget_check script with correct args", function()
        local captured
        redis.run = function(name, keys, args)
            captured = { name = name, keys = keys, args = args }
            return { 1, 100, 900 }
        end
        local ok = budget.try_consume(session_with(1000), 100)
        assert.is_true(ok)
        assert.equals("budget_check", captured.name)
        assert.equals("budget:session:sess_b", captured.keys[1])
        assert.equals(1000, captured.args[1])
        assert.equals(100,  captured.args[2])
    end)

    it("denies when the script reports allowed=0", function()
        redis.run = function() return { 0, 950, 50 } end
        local ok, used, remaining = budget.try_consume(session_with(1000), 100)
        assert.is_false(ok)
        assert.equals(950, used)
        assert.equals(50,  remaining)
    end)

    it("fails open when Redis call fails", function()
        redis.run = function() return nil, "redis down" end
        local ok = budget.try_consume(session_with(1000), 100)
        assert.is_true(ok)
    end)

    it("skips the call when consume <= 0", function()
        local called = false
        redis.run = function() called = true; return { 1, 0, 1000 } end
        local ok = budget.try_consume(session_with(1000), 0)
        assert.is_true(ok)
        assert.is_false(called)
    end)
end)

helpers.uninstall_ngx_stub()
