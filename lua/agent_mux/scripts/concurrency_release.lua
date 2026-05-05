-- scripts/concurrency_release.lua  —  release a per-org concurrency slot.
--
-- KEYS[1] = concurrency:org:<org_id>
-- ARGV[1] = session_id
--
-- Returns: 1 (released) | 0 (was not held)

local removed = redis.call('ZREM', KEYS[1], ARGV[1])
return removed and tonumber(removed) or 0
