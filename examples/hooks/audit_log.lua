-- examples/hooks/audit_log.lua  —  reference audit hook.
--
-- Logs every tool call (pre and post) as a structured line. Drop-in
-- replacement for "log every tool the agent invoked, what arguments,
-- and what came back" — useful for compliance and debugging.
--
-- Place this file (or your customised copy) under the directory pointed
-- to by AGENT_MUX_HOOKS_DIR (default: examples/hooks).

local cjson = require("cjson.safe")

local function now() return ngx.now() end

local function trim(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    return s:sub(1, n) .. "…"
end

return {
    name     = "audit_log",
    fires_on = { "pre_tool", "post_tool", "on_done", "on_cancel", "on_error" },

    run = function(event, payload)
        if event == "pre_tool" then
            ngx.log(ngx.INFO, cjson.encode({
                event       = "audit.pre_tool",
                ts          = now(),
                session_id  = payload.session and payload.session.id,
                tool_use_id = payload.use and payload.use.id,
                tool_name   = payload.use and payload.use.name,
                input_preview = payload.use and trim(cjson.encode(payload.use.input or {}), 200),
            }))
        elseif event == "post_tool" then
            ngx.log(ngx.INFO, cjson.encode({
                event       = "audit.post_tool",
                ts          = now(),
                session_id  = payload.session and payload.session.id,
                tool_use_id = payload.result and payload.result.tool_use_id,
                tool_name   = payload.use and payload.use.name,
                is_error    = payload.result and payload.result.is_error or false,
                content_preview = payload.result and trim(payload.result.content, 200),
            }))
        else
            ngx.log(ngx.INFO, cjson.encode({
                event      = "audit." .. event,
                ts         = now(),
                session_id = payload.session and payload.session.id,
                stop_reason = payload.stop_reason,
                turns      = payload.turns,
            }))
        end
    end,
}
