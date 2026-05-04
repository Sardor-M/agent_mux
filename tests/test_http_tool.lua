-- tests/test_http_tool.lua  —  HTTP tool manifest parsing + closure shape.
--
-- We don't make a real HTTP request here (the real round-trip is covered
-- by the integration demo). Instead we verify:
--   • the manifest file loader registers tools correctly
--   • make_runner produces a function with the closed-over fields we expect

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local registry = require("agent_mux.tools.registry")
local http     = require("agent_mux.tools.http")

describe("tools.http", function()
    before_each(function() registry._reset_for_test() end)

    it("register_spec adds an HTTP tool and stamps _origin", function()
        local spec = {
            name        = "search",
            description = "test",
            schema      = { type = "object" },
            url         = "http://example.com/tool",
            timeout_ms  = 1234,
        }
        local m = http.register_spec(spec)
        assert.equals("http", m._origin)
        assert.is_function(m.run)
        local got = registry.get("search")
        assert.equals(1234, got.timeout_ms)
        assert.is_function(got.run)
    end)

    it("rejects specs without a url", function()
        assert.has_error(function()
            http.register_spec({
                name = "x", description = ".", schema = {},
            })
        end)
    end)

    it("load_manifest registers the bundled http_tools.json", function()
        local registered, err = http.load_manifest("examples/tools/http_tools.json")
        assert.is_nil(err)
        assert.is_truthy(registered)
        assert.is_table(registry.get("search"))
    end)
end)

helpers.uninstall_ngx_stub()
