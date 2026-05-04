-- session/messages.lua  —  message-history mutation helpers.
--
-- All shape decisions live here so the rest of the codebase never builds
-- raw `{role, content}` literals. When the API shape evolves (e.g. multi-
-- modal blocks), this is the only file that changes.

local _M = {}

-- Anthropic-shaped user message. `content` may be a string or an array of blocks.
function _M.user(content)
    return { role = "user", content = content }
end

-- Anthropic-shaped assistant message reconstructed from an upstream Response.
-- We strip internal accumulators (`_partial_json`) before persisting.
function _M.assistant_from_response(response)
    local content = {}
    for i, block in ipairs(response.content or {}) do
        local clean = {}
        for k, v in pairs(block) do
            if k:sub(1, 1) ~= "_" then clean[k] = v end
        end
        content[i] = clean
    end
    return { role = "assistant", content = content }
end

-- Build the next user turn from a list of tool_result blocks.
-- Used in week 2 when tool dispatch lands; keeping the helper here so the
-- shape choice is centralised.
function _M.user_with_tool_results(results)
    local blocks = {}
    for i, r in ipairs(results) do
        blocks[i] = {
            type         = "tool_result",
            tool_use_id  = r.tool_use_id,
            content      = r.content,
            is_error     = r.is_error or nil,
        }
    end
    return { role = "user", content = blocks }
end

return _M
