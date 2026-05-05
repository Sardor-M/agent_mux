-- scripts/budget_check.lua  —  per-session token budget consume.
--
-- Atomic test-and-increment of a session's running token usage. If the
-- consume would exceed `max_tokens`, we DO NOT increment — the caller
-- can stop the loop with the user already-charged correctly.
--
-- KEYS[1] = budget:session:<session_id>
-- ARGV[1] = max_tokens   (cap including the current call)
-- ARGV[2] = consume      (input + output tokens of just-finished turn)
-- ARGV[3] = ttl_seconds  (key auto-expires this far after the last update)
--
-- Returns: { allowed (0|1), used_total, remaining }
--
-- Note: we use plain integer SET/INCRBY rather than a hash. Single-field
-- semantics are clearer and INCRBY is atomic by itself; we only need a
-- script for the "would this exceed cap?" check.

local key        = KEYS[1]
local max_tokens = tonumber(ARGV[1])
local consume    = tonumber(ARGV[2])
local ttl        = tonumber(ARGV[3])

local used     = tonumber(redis.call('GET', key)) or 0
local proposed = used + consume

if proposed > max_tokens then
    -- Refuse: the caller's loop will stop. Do NOT update used.
    return { 0, used, max_tokens - used }
end

redis.call('SET', key, proposed, 'EX', ttl)
return { 1, proposed, max_tokens - proposed }
