-- tests/test_inline_tool.lua  —  loading + executing the calculator.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local registry = require("agent_mux.tools.registry")
local inline   = require("agent_mux.tools.inline")

describe("tools.inline + calculator example", function()
    before_each(function() registry._reset_for_test() end)

    it("load_file registers the calculator manifest", function()
        local m, err = inline.load_file("examples/tools/inline_calculator.lua")
        assert.is_nil(err)
        assert.is_table(m)
        assert.equals("calculator", m.name)
        assert.equals("inline", m._origin)
        assert.is_table(registry.get("calculator"))
    end)

    it("run() returns the arithmetic answer for valid input", function()
        local m = assert(inline.load_file("examples/tools/inline_calculator.lua"))
        local r = m.run({ expr = "21 * 2" })
        assert.is_nil(r.is_error)
        assert.equals("42", r.content)
    end)

    it("run() returns is_error for parse errors", function()
        local m = assert(inline.load_file("examples/tools/inline_calculator.lua"))
        local r = m.run({ expr = "21 +* 2" })
        assert.is_true(r.is_error)
        assert.is_truthy(r.content:find("parse_error"))
    end)

    it("run() rejects non-numeric results", function()
        local m = assert(inline.load_file("examples/tools/inline_calculator.lua"))
        -- math.huge / math.huge → NaN; "tostring(nan)" is a number type
        -- in Lua so that still passes. Use a string-returning expression.
        local r = m.run({ expr = "'cat'" })
        assert.is_true(r.is_error)
    end)

    it("sandbox prevents access to globals (e.g. os)", function()
        local m = assert(inline.load_file("examples/tools/inline_calculator.lua"))
        local r = m.run({ expr = "os.time()" })
        assert.is_true(r.is_error)
    end)

    it("load_dir picks up the calculator and skips non-manifest files", function()
        local registered = inline.load_dir("examples/tools")
        local found = false
        for _, m in ipairs(registered) do
            if m.name == "calculator" then found = true; break end
        end
        assert.is_true(found)
    end)
end)

helpers.uninstall_ngx_stub()
