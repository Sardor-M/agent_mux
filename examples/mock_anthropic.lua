-- examples/mock_anthropic.lua  —  canned Anthropic Messages API responder.
--
-- Stateful in the request sense: we inspect the incoming `messages` array
-- to decide which canned script to play.
--
--   • If the LAST message has tool_result blocks  →  emit the FINAL text turn
--     ("here is the answer based on what you found"). stop_reason = "end_turn".
--
--   • Otherwise (initial / text-only inputs):
--       - If `metadata.scenario == "tool_use"` (or any user message contains
--         the substring "use_tools" or starts with "calc"), emit a
--         multi-tool-use turn: a calculator call AND a search call in the
--         same assistant turn. stop_reason = "tool_use".
--       - Else emit the simple single-text turn from week 1.
--         stop_reason = "end_turn".
--
-- Together these three scripts let the loop drive the full multi-turn
-- cycle: text → tool_use → tool_results → final text → end.

local cjson = require("cjson.safe")

local function emit(event, payload)
    ngx.print("event: ", event, "\n")
    ngx.print("data: ", cjson.encode(payload), "\n\n")
    ngx.flush(true)
end

-- ----- request introspection ---------------------------------------------

ngx.req.read_body()
local raw  = ngx.req.get_body_data() or ""
local req  = cjson.decode(raw) or {}
local msgs = req.messages or {}
local meta = req.metadata or {}

local function last_msg()
    return msgs[#msgs]
end

local function has_tool_results(m)
    if type(m) ~= "table" or m.role ~= "user" then return false end
    if type(m.content) ~= "table" then return false end
    for _, block in ipairs(m.content) do
        if type(block) == "table" and block.type == "tool_result" then return true end
    end
    return false
end

local function user_text(m)
    if type(m) ~= "table" then return "" end
    if type(m.content) == "string" then return m.content end
    if type(m.content) == "table" then
        for _, b in ipairs(m.content) do
            if type(b) == "table" and b.type == "text" and b.text then return b.text end
        end
    end
    return ""
end

local function wants_tools()
    if meta.scenario == "tool_use" then return true end
    -- find first user message, check its text
    for _, m in ipairs(msgs) do
        if m.role == "user" then
            local t = user_text(m):lower()
            if t:find("use_tools", 1, true) or t:find("^%s*calc") then return true end
            return false
        end
    end
    return false
end

-- ----- shared SSE headers -------------------------------------------------

ngx.header["Content-Type"]      = "text/event-stream; charset=utf-8"
ngx.header["Cache-Control"]     = "no-cache"
ngx.header["X-Accel-Buffering"] = "no"

-- ----- canned script: terminal text turn ---------------------------------

local function script_text_only(intro_text, stop_reason)
    emit("message_start", {
        type    = "message_start",
        message = {
            id    = "msg_mock_text",
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
    -- Pace a few chunks so the SSE relay is visibly streaming.
    local chunks = {}
    for piece in intro_text:gmatch("[^ ]+") do
        chunks[#chunks + 1] = piece .. " "
    end
    for _, c in ipairs(chunks) do
        emit("content_block_delta", {
            type  = "content_block_delta",
            index = 0,
            delta = { type = "text_delta", text = c },
        })
        ngx.sleep(0.03)
    end
    emit("content_block_stop", { type = "content_block_stop", index = 0 })
    emit("message_delta", {
        type  = "message_delta",
        delta = { stop_reason = stop_reason, stop_sequence = ngx.null },
        usage = { output_tokens = #chunks },
    })
    emit("message_stop", { type = "message_stop" })
end

-- ----- canned script: multi-tool-use turn --------------------------------

local function emit_tool_use_block(index, block_id, name, input_obj)
    emit("content_block_start", {
        type          = "content_block_start",
        index         = index,
        content_block = { type = "tool_use", id = block_id, name = name, input = {} },
    })
    -- Stream the JSON arguments as input_json_delta chunks (tiny, single fragment).
    emit("content_block_delta", {
        type  = "content_block_delta",
        index = index,
        delta = {
            type          = "input_json_delta",
            partial_json  = cjson.encode(input_obj),
        },
    })
    emit("content_block_stop", { type = "content_block_stop", index = index })
end

local function script_tool_use()
    emit("message_start", {
        type    = "message_start",
        message = {
            id    = "msg_mock_tools",
            type  = "message",
            role  = "assistant",
            model = "mock-claude",
            content = {},
            stop_reason = nil,
            usage = { input_tokens = 18, output_tokens = 0 },
        },
    })
    -- A short text preface — typical Claude behaviour before tool calls.
    emit("content_block_start", {
        type          = "content_block_start",
        index         = 0,
        content_block = { type = "text", text = "" },
    })
    for _, p in ipairs({"I'll ", "compute ", "and ", "look ", "that ", "up."}) do
        emit("content_block_delta", {
            type  = "content_block_delta",
            index = 0,
            delta = { type = "text_delta", text = p },
        })
        ngx.sleep(0.02)
    end
    emit("content_block_stop", { type = "content_block_stop", index = 0 })

    emit_tool_use_block(1, "toolu_calc_1",   "calculator", { expr = "21*2" })
    emit_tool_use_block(2, "toolu_search_1", "search",     { query = "what is openresty" })

    emit("message_delta", {
        type  = "message_delta",
        delta = { stop_reason = "tool_use", stop_sequence = ngx.null },
        usage = { output_tokens = 30 },
    })
    emit("message_stop", { type = "message_stop" })
end

-- ----- dispatch -----------------------------------------------------------

if has_tool_results(last_msg()) then
    script_text_only(
        "Done — the calculator returned 42 and search confirmed it. Final answer: 42.",
        "end_turn"
    )
elseif wants_tools() then
    script_tool_use()
else
    script_text_only(
        "Hello from the mock Anthropic endpoint. Add metadata.scenario='tool_use' or include 'use_tools' in your message to exercise the tool-dispatch path.",
        "end_turn"
    )
end
