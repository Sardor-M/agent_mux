-- policy/auth_request.lua  —  request-level auth (distinct from policy/auth.lua,
-- which is per-tool authorisation).
--
-- Validates the incoming HTTP request before we let it create a session.
-- Two acceptable shapes:
--
--   X-API-Key: <token>
--   Authorization: Bearer <token>
--
-- The configured key set comes from one of:
--   - AGENT_MUX_API_KEYS env var (comma-separated)
--   - AGENT_MUX_API_KEYS_FILE env var (path to a file with one key per line)
--
-- If neither is set, the harness runs in **dev mode** (allow-all). We log
-- a one-line warning at init so this is impossible to miss in prod.
--
-- This is deliberately a static set, not Redis-backed. Production
-- deployments rotating keys frequently should put a JWT validator here
-- (the worker-init pattern is identical — load keys / public keys once,
-- validate per-request).

local _M = {}

local _allowed = nil   -- set on first init(); table acts as a hash set
local _mode    = nil   -- "allow_all" | "key_required"

local function parse_csv(s)
    local out = {}
    for token in s:gmatch("[^,%s]+") do out[token] = true end
    return out
end

local function read_keys_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local out = {}
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")  -- trim
        if line ~= "" and line:sub(1, 1) ~= "#" then
            out[line] = true
        end
    end
    f:close()
    return out
end

-- Called once per worker from agent_mux.init_worker.
function _M.init()
    if _allowed ~= nil then return end   -- already initialised

    local file = os.getenv("AGENT_MUX_API_KEYS_FILE")
    if file then
        local keys, ferr = read_keys_file(file)
        if not keys then
            ngx.log(ngx.ERR, "auth_request: failed reading keys file ", file, ": ", ferr)
            _allowed, _mode = {}, "key_required"
            return
        end
        _allowed, _mode = keys, "key_required"
        ngx.log(ngx.INFO, "auth_request: loaded ",
            (function() local n = 0 for _ in pairs(keys) do n = n + 1 end return n end)(),
            " keys from ", file)
        return
    end

    local csv = os.getenv("AGENT_MUX_API_KEYS")
    if csv and csv ~= "" then
        _allowed, _mode = parse_csv(csv), "key_required"
        return
    end

    _allowed, _mode = {}, "allow_all"
    ngx.log(ngx.WARN, "auth_request: NO API KEYS CONFIGURED — running in allow-all dev mode. " ..
                      "Set AGENT_MUX_API_KEYS or AGENT_MUX_API_KEYS_FILE for production.")
end

local function extract_key(headers)
    local key = headers["X-API-Key"] or headers["x-api-key"]
    if key and key ~= "" then return key end

    local auth = headers["Authorization"] or headers["authorization"]
    if auth then
        local b = auth:match("^[Bb]earer%s+(.+)$")
        if b and b ~= "" then return b end
    end
    return nil
end

-- Returns: allowed (boolean), reason (string)
function _M.check()
    if _mode == nil then _M.init() end   -- defensive — shouldn't happen post-init_worker
    if _mode == "allow_all" then return true, "allow_all_dev" end

    local key = extract_key(ngx.req.get_headers())
    if not key then return false, "missing_api_key" end
    if not _allowed[key] then return false, "invalid_api_key" end
    return true, "ok"
end

-- Test hooks.
function _M._reset_for_test()
    _allowed = nil
    _mode    = nil
end

function _M._set_for_test(keys, mode)
    _allowed = keys or {}
    _mode    = mode or "key_required"
end

return _M
