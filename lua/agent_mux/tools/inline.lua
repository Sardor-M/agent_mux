-- tools/inline.lua  —  in-process Lua tool handlers.
--
-- An inline tool is a Lua module that returns a manifest table. The `run`
-- field is a Lua function that executes synchronously inside the worker.
-- Use inline for cheap, deterministic tools (formatters, calculators,
-- validators) — anything where the IPC round-trip of an HTTP call would
-- dwarf the actual work.
--
-- Loading a directory:
--   tools.inline.load_dir("examples/tools")
-- registers every `*.lua` whose return value passes registry's manifest
-- check. Files that don't return a manifest (helpers, libraries) are
-- skipped silently.

local registry = require("agent_mux.tools.registry")

local _M = {}

-- List `*.lua` files under `dir`. We avoid lfs (extra dep) by using
-- popen + ls; the file count is small and bounded by repo layout.
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

-- Convert "examples/tools/inline_calculator.lua" → "inline_calculator" so
-- that `loadfile + chunk()` mimics what `require` would yield, but without
-- needing the file to be on package.path.
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

    -- A non-manifest file (helper, library) returns something other than a
    -- table-with-name-and-run. Skip silently.
    if type(mod) ~= "table" or not mod.name or not mod.run then
        return nil, "not a tool manifest (missing name/run)"
    end

    mod._origin = "inline"
    return registry.register(mod)
end

function _M.load_dir(dir)
    local files = list_lua_files(dir)
    local registered = {}
    for _, path in ipairs(files) do
        local m, err = _M.load_file(path)
        if m then
            registered[#registered + 1] = m
        elseif err and not err:find("not a tool manifest", 1, true) then
            -- Real failure (parse error, runtime error). Surface it.
            if ngx and ngx.log then
                ngx.log(ngx.WARN, "inline.load_file(", path, ") failed: ", err)
            else
                io.stderr:write(("inline.load_file(%s) failed: %s\n"):format(path, err))
            end
        end
    end
    return registered
end

return _M
