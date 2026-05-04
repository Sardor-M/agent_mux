-- tests/test_tool_registry.lua  —  manifest validation + projection.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local registry = require("agent_mux.tools.registry")

local function valid_manifest()
    return {
        name        = "noop",
        description = "Does nothing.",
        schema      = { type = "object" },
        run         = function(_input, _ctx) return { content = "ok" } end,
    }
end

describe("tools.registry", function()
    before_each(function() registry._reset_for_test() end)

    it("registers a valid manifest and assigns a default timeout", function()
        local m = registry.register(valid_manifest())
        assert.equals(5000, m.timeout_ms)
        assert.is_table(registry.get("noop"))
    end)

    it("rejects manifests missing required keys", function()
        assert.has_error(function()
            registry.register({ description = "x", schema = {}, run = function() end })
        end)
        assert.has_error(function()
            registry.register({ name = "x", description = "x", schema = {} }) -- no run
        end)
    end)

    it("list returns deterministic order by name", function()
        local b = valid_manifest(); b.name = "b"
        local a = valid_manifest(); a.name = "a"
        registry.register(b); registry.register(a)
        local list = registry.list()
        assert.equals(2, #list)
        assert.equals("a", list[1].name)
        assert.equals("b", list[2].name)
    end)

    it("to_api_schema strips internal fields", function()
        registry.register(valid_manifest())
        local out = registry.to_api_schema()
        assert.equals(1, #out)
        assert.equals("noop", out[1].name)
        assert.is_nil(out[1].run)
        assert.is_nil(out[1].timeout_ms)
        assert.is_table(out[1].input_schema)
    end)
end)

helpers.uninstall_ngx_stub()
