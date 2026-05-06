-- observability/metrics.lua  —  Prometheus text-format collector.
--
-- Counters, gauges, and (as of v0.4) histograms. Per-worker storage for
-- now; lua_shared_dict-backed cross-worker aggregation is on the
-- roadmap when we need to scale beyond a single worker.

local _M = {}

-- Default histogram buckets (seconds). Tuned for LLM/agent latency:
-- 1ms → 1ms calculator tools, 100ms → P50 LLM tokens, 60s → upstream
-- timeout. Override per-metric via register().
local DEFAULT_BUCKETS = { 0.001, 0.005, 0.025, 0.1, 0.5, 1, 2.5, 5, 10, 30, 60 }

-- Metric registry. Shape per type:
--   counter / gauge: { type, help, values = { [labels_key] = number } }
--   histogram:       { type, help, buckets,
--                      values = { [labels_key] = { counts={...}, sum=N, count=N } } }
local _registry = {}

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

local function format_labels(key, extra)
    if key == "" and not extra then return "" end
    local parts = {}
    if key ~= "" then
        for k, v in key:gmatch("([^,=]+)=([^,]+)") do
            parts[#parts + 1] = string.format('%s="%s"', k, v)
        end
    end
    if extra then
        for k, v in pairs(extra) do
            parts[#parts + 1] = string.format('%s="%s"', k, v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function _M.register(name, kind, help, opts)
    if _registry[name] then return end
    local entry = { type = kind, help = help, values = {} }
    if kind == "histogram" then
        entry.buckets = (opts and opts.buckets) or DEFAULT_BUCKETS
    end
    _registry[name] = entry
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

-- Histogram observation. `value` is the measured quantity (e.g. seconds).
function _M.observe(name, labels, value)
    local entry = _registry[name]
    if not entry or entry.type ~= "histogram" then return end
    local key = labels_key(labels)
    local h = entry.values[key]
    if not h then
        h = { counts = {}, sum = 0, count = 0 }
        for i = 1, #entry.buckets do h.counts[i] = 0 end
        entry.values[key] = h
    end
    for i, le in ipairs(entry.buckets) do
        if value <= le then h.counts[i] = h.counts[i] + 1 end
    end
    h.sum   = h.sum + value
    h.count = h.count + 1
end

function _M.init()
    _M.register("agent_mux_sessions_total",      "counter", "Total agent sessions started, by status.")
    _M.register("agent_mux_turns_total",         "counter", "Total agent loop turns, by model and stop_reason.")
    _M.register("agent_mux_tool_calls_total",    "counter", "Total tool calls, by name and outcome.")
    _M.register("agent_mux_tokens_total",        "counter", "Total tokens, by direction and model.")
    _M.register("agent_mux_concurrent_sessions", "gauge",   "Currently-running agent sessions, by org.")
    _M.register("agent_mux_build_info",          "gauge",   "Build info (always 1).")
    _M.register("agent_mux_llm_latency_seconds", "histogram",
        "Upstream LLM call latency in seconds, by model.")
    _M.register("agent_mux_tool_latency_seconds", "histogram",
        "Tool handler latency in seconds, by tool name.")
    _M.register("agent_mux_session_duration_seconds", "histogram",
        "Agent session wall-clock duration, by stop_reason.",
        { buckets = { 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600 } })

    _M.set("agent_mux_build_info", { version = require("agent_mux")._VERSION }, 1)
end

-- Render a histogram entry's buckets + sum/count to Prometheus text format.
local function render_histogram(name, key, h, buckets)
    local out = {}
    local cumulative = 0
    for i, le in ipairs(buckets) do
        cumulative = h.counts[i] or 0   -- our `observe` already accumulates
        out[#out + 1] = string.format("%s_bucket%s %d\n", name,
            format_labels(key, { le = tostring(le) }), cumulative)
    end
    out[#out + 1] = string.format("%s_bucket%s %d\n", name,
        format_labels(key, { le = "+Inf" }), h.count)
    out[#out + 1] = string.format("%s_sum%s %g\n",   name, format_labels(key), h.sum)
    out[#out + 1] = string.format("%s_count%s %d\n", name, format_labels(key), h.count)
    return table.concat(out)
end

function _M.write()
    ngx.header["Content-Type"] = "text/plain; version=0.0.4"
    for name, entry in pairs(_registry) do
        ngx.print("# HELP ", name, " ", entry.help, "\n")
        ngx.print("# TYPE ", name, " ", entry.type, "\n")

        if entry.type == "histogram" then
            local has_values = false
            for k, h in pairs(entry.values) do
                ngx.print(render_histogram(name, k, h, entry.buckets))
                has_values = true
            end
            if not has_values then
                -- Show a zero-state with default buckets so dashboards know the metric exists.
                ngx.print(render_histogram(name, "", {
                    counts = (function() local c = {} for i = 1, #entry.buckets do c[i] = 0 end return c end)(),
                    sum    = 0,
                    count  = 0,
                }, entry.buckets))
            end
        else
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
end

function _M._reset_for_test()
    _registry = {}
end

return _M
