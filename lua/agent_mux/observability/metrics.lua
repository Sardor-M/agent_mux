-- observability/metrics.lua  —  Prometheus text-format collector.
--
-- A 30-line Prometheus exporter is simpler than pulling in a client lib
-- for v0.1. Counters and gauges only; histograms land in week 4 when we
-- need them for the bench.
--
-- Storage is per-worker via lua_shared_dict (preferred for cross-worker
-- aggregation) — until that's wired, this module keeps counters in a
-- module-local table so /metrics shows *something* useful in single-
-- worker dev mode.

local _M = {}

-- Metric registry: { [name] = { type = "counter"|"gauge", help = "...", values = { [labels_key] = number } } }
local _registry = {}

-- Stable label-key serialiser: { region="us", agent="alice" } → "agent=alice,region=us".
local function labels_key(labels)
    if not labels or next(labels) == nil then return "" end
    local keys = {}
    for k in pairs(labels) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(labels[k])
    end
    return table.concat(parts, ",")
end

-- Register at init time so /metrics always shows known names with 0 values.
function _M.register(name, kind, help)
    if _registry[name] then return end
    _registry[name] = { type = kind, help = help, values = {} }
end

function _M.inc(name, labels, by)
    local entry = _registry[name]
    if not entry then return end
    local key = labels_key(labels)
    entry.values[key] = (entry.values[key] or 0) + (by or 1)
end

function _M.set(name, labels, value)
    local entry = _registry[name]
    if not entry then return end
    entry.values[labels_key(labels)] = value
end

-- Called once per worker from agent_mux.init_worker(). Pre-registers the
-- counters that the implementation plan promises so an empty /metrics
-- endpoint still lists everything.
function _M.init()
    _M.register("agent_mux_sessions_total",      "counter", "Total agent sessions started, by status.")
    _M.register("agent_mux_turns_total",         "counter", "Total agent loop turns, by model and stop_reason.")
    _M.register("agent_mux_tool_calls_total",    "counter", "Total tool calls, by name and outcome.")
    _M.register("agent_mux_tokens_total",        "counter", "Total tokens, by direction and model.")
    _M.register("agent_mux_concurrent_sessions", "gauge",   "Currently-running agent sessions, by org.")
    _M.register("agent_mux_build_info",          "gauge",   "Build info (always 1).")
    _M.set("agent_mux_build_info", { version = require("agent_mux")._VERSION }, 1)
end

local function format_labels(key)
    if key == "" then return "" end
    -- "k1=v1,k2=v2" → '{k1="v1",k2="v2"}'
    local parts = {}
    for k, v in key:gmatch("([^,=]+)=([^,]+)") do
        parts[#parts + 1] = string.format('%s="%s"', k, v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Write Prometheus text format directly to the current response.
function _M.write()
    ngx.header["Content-Type"] = "text/plain; version=0.0.4"
    for name, entry in pairs(_registry) do
        ngx.print("# HELP ", name, " ", entry.help, "\n")
        ngx.print("# TYPE ", name, " ", entry.type, "\n")
        local has_values = false
        for k, v in pairs(entry.values) do
            ngx.print(name, format_labels(k), " ", v, "\n")
            has_values = true
        end
        if not has_values then
            ngx.print(name, " 0\n")
        end
    end
end

-- Test hook: nuke the registry between runs.
function _M._reset_for_test()
    _registry = {}
end

return _M
