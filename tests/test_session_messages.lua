-- tests/test_session_messages.lua  —  message-history shape helpers.
--
-- session/messages.lua is pure Lua (no ngx surface), so this is plain
-- busted. We pin the wire shapes here so the rest of the codebase can
-- never accidentally drift away from Anthropic's expected request body.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local messages = require("agent_mux.session.messages")

describe("session.messages", function()
    it("user(string) → {role='user', content=string}", function()
        local m = messages.user("hi")
        assert.equals("user", m.role)
        assert.equals("hi", m.content)
    end)

    it("assistant_from_response strips internal accumulators", function()
        local response = {
            content = {
                { type = "text", text = "answer" },
                {
                    type = "tool_use",
                    id   = "toolu_1",
                    name = "calculator",
                    input = { expr = "1+1" },
                    _partial_json = "should_not_persist",
                },
            },
        }
        local m = messages.assistant_from_response(response)
        assert.equals("assistant", m.role)
        assert.equals(2, #m.content)
        assert.equals("answer", m.content[1].text)
        assert.is_nil(m.content[2]._partial_json)
        assert.equals("calculator", m.content[2].name)
    end)

    it("user_with_tool_results builds the correct block array", function()
        local m = messages.user_with_tool_results({
            { tool_use_id = "toolu_1", content = "2", is_error = nil },
            { tool_use_id = "toolu_2", content = "boom", is_error = true },
        })
        assert.equals("user", m.role)
        assert.equals(2, #m.content)
        assert.equals("tool_result", m.content[1].type)
        assert.equals("toolu_1", m.content[1].tool_use_id)
        assert.is_nil(m.content[1].is_error)
        assert.is_true(m.content[2].is_error)
    end)
end)
