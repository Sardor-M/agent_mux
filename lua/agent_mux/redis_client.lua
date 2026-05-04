-- redis_client.lua  —  per-worker Redis connection helper + script registry.
--
-- We use `lua-resty-redis` (cosocket-based, ships with OpenResty) so calls
-- yield on I/O without blocking the worker. The `connect` / `set_keepalive`
-- pair keeps a process-wide pool warm between requests.
--
-- The script registry mirrors `redis-py.register_script(...)`:
--   1. On worker init, SCRIPT LOAD each .lua under lua/agent_mux/scripts/.
--      Cache the SHA1 in a module-local table.
--   2. On the hot path, run via EVALSHA.
--   3. On NOSCRIPT (Redis was restarted / SCRIPT FLUSH'd), fall back to EVAL,
--      which both runs the script *and* re-populates the cache. Self-healing.
--
-- Same pattern as m365-fastapi-backend/core/redis_client.py:222-224.

local resty_redis = require("resty.redis")

local _M  = {}

-- Connection params. Read from env at first connect so tests can override.
local DEFAULT_HOST = os.getenv("REDIS_HOST") or "127.0.0.1"
local DEFAULT_PORT = tonumber(os.getenv("REDIS_PORT") or 6379)
local TIMEOUT_MS   = 1000
local POOL_SIZE    = 64
local IDLE_MS      = 10000

-- Per-worker SHA cache: { [script_name] = { sha = "...", body = "..." } }
local _scripts = {}

-- Open a fresh connection. Caller must `release()` (or `close()` on error).
function _M.connect(opts)
    opts = opts or {}
    local r = resty_redis:new()
    r:set_timeouts(TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS)
    local ok, err = r:connect(opts.host or DEFAULT_HOST, opts.port or DEFAULT_PORT)
    if not ok then return nil, err end
    return r
end

-- Return the connection to the cosocket pool.
function _M.release(r)
    if not r then return end
    local ok, err = r:set_keepalive(IDLE_MS, POOL_SIZE)
    if not ok then
        ngx.log(ngx.WARN, "redis set_keepalive failed: ", err)
        r:close()
    end
end

-- Read a Lua script body from disk. Used at init time only.
local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local body = f:read("*a")
    f:close()
    return body
end

-- Load every .lua under lua/agent_mux/scripts/ into Redis and cache SHAs.
-- Called once per worker from agent_mux.init_worker (week 3+).
function _M.load_scripts(script_paths)
    local r, err = _M.connect()
    if not r then return false, err end

    for name, path in pairs(script_paths) do
        local body, ferr = read_file(path)
        if not body then
            _M.release(r)
            return false, "read " .. path .. ": " .. tostring(ferr)
        end
        local sha, lerr = r:script("LOAD", body)
        if not sha then
            _M.release(r)
            return false, "SCRIPT LOAD " .. name .. ": " .. tostring(lerr)
        end
        _scripts[name] = { sha = sha, body = body }
    end

    _M.release(r)
    return true
end

-- Run a registered script. EVALSHA fast path; on NOSCRIPT, fall back to
-- EVAL once and let the server re-cache. `keys` and `args` are arrays.
function _M.run(name, keys, args)
    local entry = _scripts[name]
    if not entry then return nil, "unknown script: " .. tostring(name) end

    local r, err = _M.connect()
    if not r then return nil, err end

    keys = keys or {}
    args = args or {}

    local res, eerr = r:evalsha(entry.sha, #keys, unpack(keys), unpack(args))

    if not res and eerr and eerr:find("NOSCRIPT", 1, true) then
        -- Redis forgot us; reload and EVAL — recaches as a side effect.
        res, eerr = r:eval(entry.body, #keys, unpack(keys), unpack(args))
    end

    _M.release(r)
    if not res then return nil, eerr end
    return res
end

-- Test hook: clear the SHA cache so reloading scripts in tests works.
function _M._reset_for_test()
    _scripts = {}
end

return _M
