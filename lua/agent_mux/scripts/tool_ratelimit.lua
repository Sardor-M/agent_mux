-- scripts/tool_ratelimit.lua  —  per-(session, tool) token bucket.
--
-- Atomic refill + consume. Solves the TOCTOU race that a multi-step
-- HGET → compute → HSET would have if two coroutines hit it at once.
--
-- KEYS[1] = ratelimit:tool:<session_id>:<tool_name>
-- ARGV[1] = capacity            (max tokens in the bucket)
-- ARGV[2] = refill_per_second   (float, e.g. 5.0 = 5 calls/sec sustained)
-- ARGV[3] = now_ms              (client clock; we don't trust Redis TIME for ms precision)
-- ARGV[4] = cost                (default 1 — how many tokens this call wants)
--
-- Returns: { allowed (0|1), remaining_tokens, retry_after_ms }
--
-- The bucket key auto-expires 60 s after the last touch so abandoned
-- session+tool combos don't accumulate forever.

local key            = KEYS[1]
local capacity       = tonumber(ARGV[1])
local refill_rate    = tonumber(ARGV[2])
local now_ms         = tonumber(ARGV[3])
local cost           = tonumber(ARGV[4]) or 1

local data = redis.call('HMGET', key, 'tokens', 'last_refill_ms')
local tokens      = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now_ms

-- Refill based on elapsed time. min() caps at capacity so a long
-- silence doesn't suddenly grant unlimited burst on first call.
local elapsed_ms = math.max(0, now_ms - last_refill)
local refill     = (elapsed_ms / 1000) * refill_rate
tokens = math.min(capacity, tokens + refill)

if tokens < cost then
    -- Update last_refill so the next caller's refill calc is correct.
    redis.call('HSET', key, 'tokens', tokens, 'last_refill_ms', now_ms)
    redis.call('PEXPIRE', key, 60000)
    local need     = cost - tokens
    local retry_ms = math.ceil((need / refill_rate) * 1000)
    return { 0, tokens, retry_ms }
end

tokens = tokens - cost
redis.call('HSET', key, 'tokens', tokens, 'last_refill_ms', now_ms)
redis.call('PEXPIRE', key, 60000)
return { 1, tokens, 0 }
