-- session/store.lua  —  Redis-backed session CRUD.
--
-- Stub for v0.1 scaffolding. Real implementation lands in week 1.
-- Schema and operations are documented in docs/IMPLEMENTATION_PLAN.md §9.
--
-- Public surface (planned):
--   create(req)           → session
--   load(session_id)      → session | nil, err
--   flush(session)        → ok | nil, err     (debounced write-back)
--   complete(session)     → ok                 (terminal state, longer TTL)
--   resume(session_id)    → session | nil, err

local _M = {}

function _M.create(_req)
    error("session.store.create() not implemented yet — week 1 milestone")
end

function _M.load(_session_id)
    error("session.store.load() not implemented yet — week 1 milestone")
end

function _M.flush(_session)
    error("session.store.flush() not implemented yet — week 1 milestone")
end

function _M.complete(_session)
    error("session.store.complete() not implemented yet — week 1 milestone")
end

return _M
