-- tests/test_jsonrpc.lua  —  JSON-RPC 2.0 framing helpers.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local jsonrpc = require("agent_mux.transport.jsonrpc")

describe("transport.jsonrpc", function()
    it("request includes jsonrpc, method, id, params", function()
        local r = jsonrpc.request("foo", { bar = 1 })
        assert.equals("2.0", r.jsonrpc)
        assert.equals("foo", r.method)
        assert.is_number(r.id)
        assert.equals(1, r.params.bar)
    end)

    it("notification has no id field", function()
        local n = jsonrpc.notification("ping", {})
        assert.is_nil(n.id)
        assert.equals("ping", n.method)
    end)

    it("monotonic id generator increments", function()
        local a = jsonrpc.request("x")
        local b = jsonrpc.request("y")
        assert.is_true(b.id > a.id)
    end)

    it("decode rejects non-2.0 versions", function()
        local v, err = jsonrpc.decode('{"jsonrpc":"1.0","method":"x"}')
        assert.is_nil(v)
        assert.is_truthy(err:find("jsonrpc version"))
    end)

    it("decode round-trips a request", function()
        local req = jsonrpc.request("foo", { x = 42 }, 7)
        local back = jsonrpc.decode(jsonrpc.encode(req))
        assert.equals("foo", back.method)
        assert.equals(7, back.id)
        assert.equals(42, back.params.x)
    end)

    it("kind classifies messages", function()
        assert.equals("request",          jsonrpc.kind(jsonrpc.request("a")))
        assert.equals("notification",     jsonrpc.kind(jsonrpc.notification("a")))
        assert.equals("success_response", jsonrpc.kind(jsonrpc.success_response(1, {})))
        assert.equals("error_response",   jsonrpc.kind(jsonrpc.error_response(1, -32601, "x")))
    end)

    it("error_response carries the error object", function()
        local e = jsonrpc.error_response(99, jsonrpc.METHOD_NOT_FOUND, "no such method")
        assert.equals(99, e.id)
        assert.equals(jsonrpc.METHOD_NOT_FOUND, e.error.code)
        assert.equals("no such method", e.error.message)
    end)
end)

helpers.uninstall_ngx_stub()
