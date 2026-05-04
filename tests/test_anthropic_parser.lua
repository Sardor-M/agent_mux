-- tests/test_anthropic_parser.lua  —  exercises the per-event aggregator
-- used by upstream/anthropic.lua against canned wire payloads.
--
-- We don't make a real HTTP call here (that's an integration test for
-- later); we synthesise the SSE bytes the mock would send and run them
-- through the parser + apply_event to assert the aggregated response.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()  -- anthropic.lua uses ngx.log on warnings

local Stream = require("agent_mux.upstream.stream")
local cjson  = require("cjson.safe")

-- Pull the same apply_event behaviour by re-deriving the aggregation
-- inline. We can't easily reach into anthropic.lua's local; the test
-- doubles as a contract spec for what aggregation must produce.
local function aggregate(sse_bytes)
    local response = {
        content = {}, usage = {}, _terminated = false, role = "assistant",
    }
    local s = Stream.new()
    for _, ev in ipairs(s:feed(sse_bytes)) do
        local payload = cjson.decode(ev.data) or {}
        local et = ev.event

        if et == "message_start" and payload.message then
            response.id    = payload.message.id
            response.model = payload.message.model
            response.usage = payload.message.usage or response.usage
        elseif et == "content_block_start" then
            local block = payload.content_block or {}
            block.text = block.text or ""
            response.content[payload.index + 1] = block
        elseif et == "content_block_delta" then
            local block = response.content[payload.index + 1]
            if block and payload.delta and payload.delta.type == "text_delta" then
                block.text = block.text .. (payload.delta.text or "")
            end
        elseif et == "message_delta" then
            if payload.delta then
                response.stop_reason = payload.delta.stop_reason or response.stop_reason
            end
            if payload.usage then
                for k, v in pairs(payload.usage) do response.usage[k] = v end
            end
        elseif et == "message_stop" then
            response._terminated = true
        end
    end
    return response
end

local function ev(name, payload)
    return ("event: %s\ndata: %s\n\n"):format(name, cjson.encode(payload))
end

describe("anthropic SSE aggregation", function()
    it("aggregates a vanilla single-text-block turn", function()
        local bytes =
            ev("message_start", {
                type = "message_start",
                message = { id = "msg_1", type = "message", role = "assistant",
                            model = "mock-claude", content = {},
                            usage = { input_tokens = 12, output_tokens = 0 } },
            })
            .. ev("content_block_start", { type = "content_block_start", index = 0,
                  content_block = { type = "text", text = "" } })
            .. ev("content_block_delta", { type = "content_block_delta", index = 0,
                  delta = { type = "text_delta", text = "Hello, " } })
            .. ev("content_block_delta", { type = "content_block_delta", index = 0,
                  delta = { type = "text_delta", text = "world." } })
            .. ev("content_block_stop", { type = "content_block_stop", index = 0 })
            .. ev("message_delta", { type = "message_delta",
                  delta = { stop_reason = "end_turn", stop_sequence = cjson.null },
                  usage = { output_tokens = 4 } })
            .. ev("message_stop", { type = "message_stop" })

        local r = aggregate(bytes)

        assert.is_true(r._terminated)
        assert.equals("end_turn", r.stop_reason)
        assert.equals("msg_1", r.id)
        assert.equals(1, #r.content)
        assert.equals("Hello, world.", r.content[1].text)
        assert.equals(12, r.usage.input_tokens)
        assert.equals(4,  r.usage.output_tokens)
    end)

    it("survives an empty stream cleanly", function()
        local r = aggregate("")
        assert.is_false(r._terminated)
    end)
end)

helpers.uninstall_ngx_stub()
