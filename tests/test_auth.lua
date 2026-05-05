-- tests/test_auth.lua  —  policy/auth allow + deny resolution.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local auth = require("agent_mux.policy.auth")

local function session_with(policy)
    return { id = "sess_x", tool_policy = policy }
end

describe("policy.auth.check", function()
    it("allows by default when no policy is set", function()
        local ok, reason = auth.check({ id = "sess" }, "calculator")
        assert.is_true(ok)
        assert.equals("no_policy_default_allow", reason)
    end)

    it("allows everything under mode=allow_all", function()
        local ok, reason = auth.check(session_with({ mode = "allow_all" }), "anything")
        assert.is_true(ok)
        assert.equals("allow_all", reason)
    end)

    it("denies everything under mode=deny_all", function()
        local ok, reason = auth.check(session_with({ mode = "deny_all" }), "calculator")
        assert.is_false(ok)
        assert.equals("deny_all", reason)
    end)

    it("deny list always wins, even with allow_all", function()
        local ok, reason = auth.check(
            session_with({ mode = "allow_all", deny = { "fs.delete" } }),
            "fs.delete")
        assert.is_false(ok)
        assert.equals("deny_list", reason)
    end)

    it("allow list permits explicit names only", function()
        local p = { mode = "list", allow = { "calculator", "search" } }
        assert.is_true(auth.check(session_with(p), "calculator"))
        assert.is_true(auth.check(session_with(p), "search"))
        local ok = auth.check(session_with(p), "shell")
        assert.is_false(ok)
    end)

    it("fails closed when no allow list and not allow_all", function()
        local ok, reason = auth.check(session_with({ mode = "list" }), "calculator")
        assert.is_false(ok)
        assert.equals("no_allow_list_fail_closed", reason)
    end)
end)

helpers.uninstall_ngx_stub()
