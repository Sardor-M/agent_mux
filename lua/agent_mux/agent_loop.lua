-- agent_loop.lua  —  the multi-turn LLM ↔ tool loop.
--
-- The conceptual core of the project. See docs/IMPLEMENTATION_PLAN.md §7.
-- This file is deliberately a stub for v0.1 scaffolding; the real loop
-- arrives in week 1.
--
-- Sketch of the body (do not implement here yet):
--
--   while true do
--       hooks.fire("pre_llm", session)
--       response = upstream.call(session.model, session.messages, session.tools, ...)
--       session:append_assistant(response)
--       budget.consume(session, response.usage)
--       hooks.fire("post_llm", session, response)
--       if response.stop_reason ~= "tool_use" then break end
--       results = dispatcher.run_concurrent(session, response:tool_uses(), sse_writer)
--       session:append_user_with_tool_results(results)
--   end
--   sse_writer:emit("done", { stop_reason = response.stop_reason })

local _M = {}
_M.__index = _M

function _M.new(_session)
    return setmetatable({ _todo = "week-1" }, _M)
end

function _M:run(_sse_writer)
    error("agent_loop.run() not implemented yet — week 1 milestone")
end

return _M
