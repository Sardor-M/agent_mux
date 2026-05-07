-- session/store.lua  —  Redis-backed session CRUD.
--
-- Schema (one Redis key per session, JSON-encoded):
--
--   session:<session_id>  →  {
--     id, schema_version, model, agent_id, org_id,
--     messages,           ← Anthropic-shaped array
--     tools,              ← schemas pass-through (week 2 will use)
--     tool_policy,
--     usage,              ← { input_tokens, output_tokens }
--     budget,             ← { max_tokens, wall_clock_ms }
--     status,             ← "running" | "completed" | "cancelled" | "errored"
--     created_at, updated_at,
--     stop_reason         ← present when status != "running"
--   }
--
-- TTL: while running, 1h (so a wedged session can't pin memory forever).
-- On `complete()` we extend the TTL to 24h so post-mortems work.

local cjson      = require("cjson.safe")
local redis      = require("agent_mux.redis_client")
local messages   = require("agent_mux.session.messages")
local migrations = require("agent_mux.session.migrations")
local log        = require("agent_mux.observability.log")

local _M = {}

local SCHEMA_VERSION = 1
local KEY_PREFIX     = "session:"
local TTL_RUNNING    = 3600          -- 1h
local TTL_COMPLETED  = 86400         -- 24h

local function now_ts() return ngx.time() end

-- session_id: 24 hex chars from random bytes. Sufficient for v0.1; the
-- caller can always supply their own via the request body.
local function gen_id()
    -- math.random in OpenResty workers is seeded per-worker; that's fine
    -- for non-security identifiers.
    local parts = {}
    for i = 1, 6 do parts[i] = string.format("%04x", math.random(0, 0xffff)) end
    return "sess_" .. table.concat(parts)
end

local function key_for(session_id) return KEY_PREFIX .. session_id end

-- Wrap a plain table with a metatable that exposes mutation helpers. The
-- agent loop and server use only this surface; raw table fields are read-only
-- by convention.
local Session = {}
Session.__index = Session

function Session:append_user(content)
    table.insert(self.messages, messages.user(content))
    self.updated_at = now_ts()
end

function Session:append_assistant(response)
    table.insert(self.messages, messages.assistant_from_response(response))
    if response.usage then
        self.usage.input_tokens  = (self.usage.input_tokens  or 0) + (response.usage.input_tokens  or 0)
        self.usage.output_tokens = (self.usage.output_tokens or 0) + (response.usage.output_tokens or 0)
    end
    self.stop_reason = response.stop_reason
    self.updated_at = now_ts()
end

-- Week 2 will use this. Keeping it here so the loop's shape is symmetric.
function Session:append_user_with_tool_results(results)
    table.insert(self.messages, messages.user_with_tool_results(results))
    self.updated_at = now_ts()
end

-- Encode just the persistable fields. Methods (Session metatable) are dropped.
local function encode_doc(s)
    return cjson.encode({
        id                = s.id,
        schema_version    = s.schema_version,
        model             = s.model,
        agent_id          = s.agent_id,
        org_id            = s.org_id,
        messages          = s.messages,
        tools             = s.tools,
        tool_policy       = s.tool_policy,
        usage             = s.usage,
        budget            = s.budget,
        status            = s.status,
        stop_reason       = s.stop_reason,
        cancel_requested  = s.cancel_requested or nil,
        created_at        = s.created_at,
        updated_at        = s.updated_at,
    })
end

local function wrap(doc)
    return setmetatable(doc, Session)
end

-- Create a new session and persist it. `req` is the parsed request body
-- plus headers we care about; minimum required keys are `model` and `messages`.
function _M.create(req)
    assert(req.model,    "session.create: req.model is required")
    assert(req.messages, "session.create: req.messages is required")

    local s = wrap({
        id              = req.session_id or gen_id(),
        schema_version  = SCHEMA_VERSION,
        model           = req.model,
        agent_id        = req.agent_id,
        org_id          = req.org_id,
        messages        = req.messages,
        tools           = req.tools or {},
        tool_policy     = req.tool_policy or { mode = "allow_all" },
        usage           = { input_tokens = 0, output_tokens = 0 },
        budget          = req.budget or {
            max_tokens     = 200000,
            wall_clock_ms  = 600000,
        },
        status          = "running",
        created_at      = now_ts(),
        updated_at      = now_ts(),
    })

    local ok, err = _M.flush(s)
    if not ok then return nil, err end
    log.info("session_created", { session_id = s.id, model = s.model })
    return s
end

-- Load a session by id. Returns nil + "not_found" if missing.
function _M.load(session_id)
    local r, err = redis.connect()
    if not r then return nil, err end
    local raw, gerr = r:get(key_for(session_id))
    redis.release(r)

    if gerr then return nil, gerr end
    if raw == ngx.null or raw == nil then return nil, "not_found" end

    local doc, derr = cjson.decode(raw)
    if not doc then return nil, "decode: " .. tostring(derr) end

    -- Schema-version handling: apply pending migrations if the doc is
    -- behind. Migrations are pure (no Redis access), so we apply then
    -- re-flush. If we're ahead (newer worker reading older worker's
    -- doc), that's fine; we just log it.
    if doc.schema_version and doc.schema_version < SCHEMA_VERSION then
        -- pcall returns (ok, ...returns_of_apply); apply returns (doc, count).
        local ok, new_doc, applied = pcall(migrations.apply, doc, SCHEMA_VERSION)
        if not ok then
            log.error("session_migration_failed", {
                session_id = session_id,
                from       = doc.schema_version,
                to         = SCHEMA_VERSION,
                err        = tostring(new_doc),   -- on failure new_doc holds the error
            })
            return nil, "migration_failed"
        end
        doc = new_doc
        log.info("session_migrated", {
            session_id = session_id,
            applied    = applied,
            now        = doc.schema_version,
        })
        -- Re-flush so subsequent loads skip migration. Wrapped first
        -- because flush expects a Session object.
        local s = wrap(doc)
        local ok, ferr = _M.flush(s)
        if not ok then
            log.warn("session_migration_flush_failed", { session_id = session_id, err = ferr })
        end
        return s
    elseif doc.schema_version and doc.schema_version > SCHEMA_VERSION then
        log.warn("session_schema_ahead", {
            session_id = session_id,
            on_disk    = doc.schema_version,
            we_know    = SCHEMA_VERSION,
        })
    end
    return wrap(doc)
end

-- Persist `s` to Redis. v0.1 flushes on every state transition; week 4
-- introduces debouncing once metrics show this matters.
function _M.flush(s)
    local r, err = redis.connect()
    if not r then return false, err end
    local ttl = (s.status == "running") and TTL_RUNNING or TTL_COMPLETED
    local ok, serr = r:set(key_for(s.id), encode_doc(s), "EX", ttl)
    redis.release(r)
    if not ok then return false, serr end
    return true
end

-- Mark terminal status, write back with extended TTL.
function _M.complete(s, stop_reason)
    s.status      = "completed"
    s.stop_reason = stop_reason or s.stop_reason
    s.updated_at  = now_ts()
    return _M.flush(s)
end

function _M.cancel(s)
    s.status     = "cancelled"
    s.updated_at = now_ts()
    return _M.flush(s)
end

-- Signal a running session to cancel itself. Writes a single field via a
-- dedicated key namespace so we don't need to read-modify-write the whole
-- doc — the agent loop's worker may be holding the doc in memory and
-- our flush would lose its in-flight changes.
--
-- The loop checks the cancel signal between turns by reading this key.
function _M.signal_cancel(session_id)
    local r, err = redis.connect()
    if not r then return false, err end
    -- 60s TTL: by then either the loop noticed and acked, or the session
    -- itself has TTL'd out.
    local ok, serr = r:set("cancel:session:" .. session_id, "1", "EX", 60)
    redis.release(r)
    if not ok then return false, serr end
    return true
end

-- Cheap probe — single GET of a small string. Called from agent_loop
-- once per turn (i.e. at most a few times per minute per session).
function _M.is_cancel_requested(session)
    local r, err = redis.connect()
    if not r then return false end
    local v, gerr = r:get("cancel:session:" .. session.id)
    redis.release(r)
    if gerr then return false end
    return v == "1"
end

-- Clear the cancel signal once we've acted on it. Best-effort — the
-- 60s TTL is the safety net.
function _M.clear_cancel_signal(session_id)
    local r, err = redis.connect()
    if not r then return end
    r:del("cancel:session:" .. session_id)
    redis.release(r)
end

function _M.error(s, err_msg)
    s.status      = "errored"
    s.stop_reason = "error: " .. tostring(err_msg)
    s.updated_at  = now_ts()
    return _M.flush(s)
end

-- Test/CLI hook: render the persisted JSON for `/v1/sessions/:id`.
function _M.to_json(s)
    return encode_doc(s)
end

return _M
