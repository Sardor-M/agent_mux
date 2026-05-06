-- hooks/loader.lua  —  loads hook files from a directory at init_worker.
--
-- A hook file returns a manifest table:
--
--   return {
--       name     = "audit_log",
--       fires_on = { "pre_tool", "post_tool" },
--       run      = function(event, payload) ... end,
--   }
--
-- The loader walks the directory once at worker startup. For v0.1 we do
-- NOT auto-reload — true filewatcher hot-reload (via ngx.timer.every)
-- is a stretch goal. Operators restart the worker for hook changes,
-- which is fast (~100ms) and avoids the "did the new hook actually take
-- effect?" debugging confusion.

local runtime = require("agent_mux.hooks.runtime")

local _M = {}

local function list_lua_files(dir)
    local out = {}
    local cmd = string.format([[find %q -maxdepth 1 -type f -name "*.lua" 2>/dev/null]], dir)
    local pipe = io.popen(cmd)
    if not pipe then return out end
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
    table.sort(out)
    return out
end

local function load_module(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, "loadfile: " .. tostring(err) end
    local ok, mod = pcall(chunk)
    if not ok then return nil, "exec: " .. tostring(mod) end
    return mod
end

function _M.load_file(path)
    local mod, err = load_module(path)
    if not mod then return nil, err end

    if type(mod) ~= "table" or not mod.name or not mod.run or
       not mod.fires_on or type(mod.fires_on) ~= "table" then
        return nil, "not a hook manifest (need name, fires_on, run)"
    end

    -- One register per event the hook listens on.
    for _, event in ipairs(mod.fires_on) do
        runtime.register(event, { name = mod.name, run = mod.run })
    end
    return mod
end

function _M.load_dir(dir)
    local files = list_lua_files(dir)
    local registered = {}
    for _, path in ipairs(files) do
        local m, err = _M.load_file(path)
        if m then
            registered[#registered + 1] = m
        elseif err and not err:find("not a hook manifest", 1, true) then
            if ngx and ngx.log then
                ngx.log(ngx.WARN, "hooks.load_file(", path, ") failed: ", err)
            else
                io.stderr:write(("hooks.load_file(%s) failed: %s\n"):format(path, err))
            end
        end
    end
    return registered
end

return _M
