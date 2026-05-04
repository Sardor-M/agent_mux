-- examples/mock_anthropic.lua  —  canned Anthropic Messages API responder.
--
-- Served by nginx as a `content_by_lua_file` route at /mock/v1/messages.
-- v0.1 scaffolding emits a tiny single-turn SSE response so the agent loop
-- (when it lands in week 1) has something realistic to consume.
--
-- The real Anthropic Messages streaming format (https://docs.anthropic.com/
-- en/api/messages-streaming) sends `message_start`, `content_block_start`,
-- `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
-- events, each with a `data:` JSON payload. We approximate that shape so
-- our upstream/anthropic.lua parser can be tested against it later.

local cjson = require("cjson.safe")

local function emit(event, payload)
    ngx.print("event: ", event, "\n")
    ngx.print("data: ", cjson.encode(payload), "\n\n")
    ngx.flush(true)
end

ngx.header["Content-Type"]    = "text/event-stream; charset=utf-8"
ngx.header["Cache-Control"]   = "no-cache"
ngx.header["X-Accel-Buffering"] = "no"

emit("message_start", {
    type    = "message_start",
    message = {
        id    = "msg_mock_001",
        type  = "message",
        role  = "assistant",
        model = "mock-claude",
        content = {},
        stop_reason = nil,
        usage = { input_tokens = 12, output_tokens = 0 },
    },
})

emit("content_block_start", {
    type          = "content_block_start",
    index         = 0,
    content_block = { type = "text", text = "" },
})

local chunks = { "Hello", " from ", "the ", "mock ", "Anthropic ", "endpoint." }
for _, c in ipairs(chunks) do
    emit("content_block_delta", {
        type  = "content_block_delta",
        index = 0,
        delta = { type = "text_delta", text = c },
    })
    -- Crude pacing so a curl client visibly observes the stream.
    ngx.sleep(0.05)
end

emit("content_block_stop", { type = "content_block_stop", index = 0 })

emit("message_delta", {
    type  = "message_delta",
    delta = { stop_reason = "end_turn", stop_sequence = ngx.null },
    usage = { output_tokens = 11 },
})

emit("message_stop", { type = "message_stop" })
