-- session/migrations.lua  —  ordered schema migrations for session docs.
--
-- The pattern: each migration upgrades a document from version N to
-- version N+1. `apply(doc)` runs every pending migration in order until
-- the doc reaches the current schema version.
--
-- Each migration is a pure function: takes a doc table, returns the
-- migrated doc. It must NOT touch Redis — store.load() handles the
-- re-flush after migrations succeed.
--
-- To add a migration when you change the schema:
--   1. Bump SCHEMA_VERSION in session/store.lua.
--   2. Append a `{ from = N, to = N+1, migrate = function(doc) ... end }`
--      entry to the MIGRATIONS list below.
--   3. Test against a doc with the old schema_version.

local _M = {}

-- The list. Order matters — migrations run from `from = current` upward
-- until we reach the target version. Don't reorder existing entries.
local MIGRATIONS = {
    -- Example placeholder — uncomment when bumping to schema 2:
    -- {
    --     from = 1, to = 2,
    --     migrate = function(doc)
    --         doc.cancel_requested = nil   -- now lives in a separate Redis key
    --         return doc
    --     end,
    -- },
}

-- apply(doc, target_version) → migrated_doc, applied_count
--
-- Walks MIGRATIONS in order, applying any whose `from` matches the doc's
-- current schema_version. Each migration's `to` becomes the new current
-- version. Stops when the target is reached, or raises if no path exists.
function _M.apply(doc, target_version)
    local current = doc.schema_version or 0
    local applied = 0

    while current < target_version do
        local found = false
        for _, m in ipairs(MIGRATIONS) do
            if m.from == current then
                doc = m.migrate(doc)
                doc.schema_version = m.to
                current = m.to
                applied = applied + 1
                found = true
                break
            end
        end
        if not found then
            error(string.format(
                "no migration path from schema_version %d (target %d) — " ..
                "session is unrecoverable, see session/migrations.lua",
                current, target_version))
        end
    end

    return doc, applied
end

-- Test hooks.
_M._migrations = MIGRATIONS

function _M._set_for_test(list)
    MIGRATIONS = list
    _M._migrations = list
end

return _M
