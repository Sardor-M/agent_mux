-- tests/test_mcp_gateway.lua  —  northbound MCP gateway JSON-RPC handler.
--
-- Exercises gateway.mcp_server.handle for the MCP methods agent_mux serves,
-- confirming: registry projection into inputSchema shape, that tools/call
-- flows through the real dispatcher policy path (rate-limit fail-open under
-- the redis stub), and that tool failures surface as MCP `isError` content
-- rather than JSON-RPC protocol errors.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")

describe("gateway.mcp_server", function()
    local gateway, registry

    local function session() return { id = "gw_test", tool_policy = nil } end

    before_each(function()
        helpers.install_ngx_stub()
        gateway  = require("agent_mux.gateway.mcp_server")
        registry = require("agent_mux.tools.registry")
        registry._reset_for_test()
    end)

    after_each(function() helpers.uninstall_ngx_stub() end)

    it("initialize returns serverInfo and a tools capability", function()
        local resp = gateway.handle(
            { jsonrpc = "2.0", id = 1, method = "initialize", params = {} }, session())
        assert.equals("2.0", resp.jsonrpc)
        assert.equals(1, resp.id)
        assert.equals("agent_mux", resp.result.serverInfo.name)
        assert.is_table(resp.result.capabilities.tools)
        assert.is_string(resp.result.protocolVersion)
    end)

    it("a notification (no id) produces no response", function()
        local resp = gateway.handle(
            { jsonrpc = "2.0", method = "notifications/initialized" }, session())
        assert.is_nil(resp)
    end)

    it("ping returns an empty result", function()
        local resp = gateway.handle({ jsonrpc = "2.0", id = 9, method = "ping" }, session())
        assert.is_table(resp.result)
    end)

    it("tools/list projects the registry (schema -> inputSchema)", function()
        registry.register({
            name = "calc", description = "adds", schema = { type = "object" },
            run = function() end,
        })
        local resp = gateway.handle(
            { jsonrpc = "2.0", id = 2, method = "tools/list" }, session())
        assert.equals(1, #resp.result.tools)
        local t = resp.result.tools[1]
        assert.equals("calc", t.name)
        assert.equals("adds", t.description)
        assert.is_table(t.inputSchema)
        assert.is_nil(t.schema)
    end)

    it("tools/call dispatches and returns MCP text content", function()
        registry.register({
            name = "echo", description = ".", schema = {},
            run = function(input) return { content = "hi:" .. (input.x or "") } end,
        })
        local resp = gateway.handle({
            jsonrpc = "2.0", id = 3, method = "tools/call",
            params = { name = "echo", arguments = { x = "yo" } },
        }, session())
        assert.equals("text", resp.result.content[1].type)
        assert.equals("hi:yo", resp.result.content[1].text)
        assert.is_false(resp.result.isError)
    end)

    it("tools/call surfaces a handler crash as isError content", function()
        registry.register({
            name = "boom", description = ".", schema = {},
            run = function() error("kaboom") end,
        })
        local resp = gateway.handle({
            jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "boom" },
        }, session())
        assert.is_true(resp.result.isError)
        assert.is_truthy(resp.result.content[1].text:find("handler_error"))
    end)

    it("tools/call for an unknown tool is isError, not a protocol error", function()
        local resp = gateway.handle({
            jsonrpc = "2.0", id = 7, method = "tools/call", params = { name = "ghost" },
        }, session())
        assert.is_table(resp.result)          -- not resp.error
        assert.is_true(resp.result.isError)
        assert.is_truthy(resp.result.content[1].text:find("not registered"))
    end)

    it("tools/call without a name is an invalid-params protocol error", function()
        local resp = gateway.handle({
            jsonrpc = "2.0", id = 5, method = "tools/call", params = {},
        }, session())
        assert.is_table(resp.error)
        assert.equals(-32602, resp.error.code)  -- INVALID_PARAMS
    end)

    it("an unknown method returns method_not_found", function()
        local resp = gateway.handle(
            { jsonrpc = "2.0", id = 6, method = "resources/subscribe" }, session())
        assert.is_table(resp.error)
        assert.equals(-32601, resp.error.code)  -- METHOD_NOT_FOUND
    end)
end)
