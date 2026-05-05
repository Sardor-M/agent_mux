-- scripts/concurrency_claim.lua  —  atomic per-org concurrency slot claim.
--
-- We use a Redis ZSET with `score = now_ms` and `member = session_id`.
-- "Currently active sessions" = ZSET entries with score > now_ms - ttl_ms.
-- Stale entries (member whose score is older than the TTL) are evicted
-- on every claim — that handles the case where a worker crashed before
-- it could call release.
--
-- KEYS[1] = concurrency:org:<org_id>
-- ARGV[1] = session_id
-- ARGV[2] = max_concurrent
-- ARGV[3] = now_ms
-- ARGV[4] = ttl_ms      (max session lifetime; eviction window)
--
-- Returns: { claimed (0|1), current_count }

local key            = KEYS[1]
local session_id     = ARGV[1]
local max_concurrent = tonumber(ARGV[2])
local now_ms         = tonumber(ARGV[3])
local ttl_ms         = tonumber(ARGV[4])

-- Evict stale slots before counting.
local stale_before = now_ms - ttl_ms
redis.call('ZREMRANGEBYSCORE', key, '-inf', stale_before)

local current = tonumber(redis.call('ZCARD', key)) or 0

-- Idempotent re-claim: if our session already holds a slot, refresh
-- its score and report the current count unchanged.
if redis.call('ZSCORE', key, session_id) then
    redis.call('ZADD', key, now_ms, session_id)
    redis.call('PEXPIRE', key, ttl_ms * 2)
    return { 1, current }
end

if current >= max_concurrent then
    return { 0, current }
end

redis.call('ZADD', key, now_ms, session_id)
redis.call('PEXPIRE', key, ttl_ms * 2)
return { 1, current + 1 }
