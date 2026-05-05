-- policy/auth.lua  —  per-session tool authorisation.
--
-- The dispatcher consults this module before invoking any tool handler.
-- Decisions are made from the session's `tool_policy` field — owned by
-- the request payload, so different agent runs can have different rules.
--
-- Policy shape:
--   tool_policy = {
--       mode  = "allow_all" | "deny_all" | "list",
--       allow = { "calculator", "search" },   -- explicit allow list
--       deny  = { "fs.delete", "shell" },     -- explicit deny list
--   }
--
-- Resolution rules (in order):
--   1. If `deny` contains the tool name → DENY (deny always wins).
--   2. If mode is "allow_all" → ALLOW.
--   3. If mode is "deny_all" → DENY.
--   4. If `allow` is set → ALLOW only if the tool is in it.
--   5. Otherwise → DENY (fail closed).

local _M = {}

local function in_list(list, name)
    if type(list) ~= "table" then return false end
    for _, n in ipairs(list) do
        if n == name then return true end
    end
    return false
end

-- Returns: allowed (boolean), reason (string)
function _M.check(session, tool_name)
    local p = session and session.tool_policy
    if not p then
        -- No policy on the session means the operator never configured one;
        -- default to allow-all for parity with v0.1 behaviour.
        return true, "no_policy_default_allow"
    end

    if in_list(p.deny, tool_name) then
        return false, "deny_list"
    end

    if p.mode == "allow_all" then
        return true, "allow_all"
    end

    if p.mode == "deny_all" then
        return false, "deny_all"
    end

    -- mode == "list" or nil → allow only what's explicitly listed
    if p.allow and #p.allow > 0 then
        if in_list(p.allow, tool_name) then
            return true, "allow_list"
        end
        return false, "not_in_allow_list"
    end

    -- No allow list and not allow_all → fail closed.
    return false, "no_allow_list_fail_closed"
end

return _M
