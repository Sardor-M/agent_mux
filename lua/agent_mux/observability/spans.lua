-- observability/spans.lua  —  OpenTelemetry-shaped span emission.
--
-- Each span is emitted as one structured log line with the OTel-spec
-- fields (https://opentelemetry.io/docs/concepts/signals/traces/). For
-- v0.1 we don't ship an OTLP exporter — any log aggregator that parses
-- JSON (Loki, Datadog, fluentbit) ingests these directly. An explicit
-- exporter is a stretch goal for v0.5+.
--
-- Usage:
--
--   local sp = spans.start("agent_loop.turn", { turn = 1 }, parent_span)
--   ... do work ...
--   spans.finish(sp, { stop_reason = "end_turn" })
--
-- Hierarchies are linked via `parent_span_id`. The first span in a
-- request has no parent and gets a fresh `trace_id`.

local cjson = require("cjson.safe")

local _M = {}

local function rand_hex(bytes)
    local parts = {}
    for i = 1, bytes do
        parts[i] = string.format("%02x", math.random(0, 0xff))
    end
    return table.concat(parts)
end

-- 16 hex chars = 8 bytes = 64 bits. OTel actually wants 128-bit trace
-- ids; for an internal-only telemetry pipeline 64 is plenty.
local function new_trace_id() return rand_hex(8) end
local function new_span_id()  return rand_hex(4) end

-- Start a span. `parent` is another span or nil; pass to nested calls so
-- the hierarchy threads through correctly.
function _M.start(name, attributes, parent)
    return {
        name           = name,
        trace_id       = (parent and parent.trace_id) or new_trace_id(),
        span_id        = new_span_id(),
        parent_span_id = parent and parent.span_id or nil,
        start_ns       = ngx.now() * 1e9,
        attributes     = attributes or {},
    }
end

-- Finish a span by emitting it. Additional attributes can be merged in
-- (e.g. final stop_reason, status). Once emitted, do not modify.
function _M.finish(span, extra_attrs)
    if not span then return end
    span.end_ns = ngx.now() * 1e9
    span.duration_ns = span.end_ns - span.start_ns
    if extra_attrs then
        for k, v in pairs(extra_attrs) do span.attributes[k] = v end
    end

    ngx.log(ngx.INFO, cjson.encode({
        event           = "span",
        name            = span.name,
        trace_id        = span.trace_id,
        span_id         = span.span_id,
        parent_span_id  = span.parent_span_id,
        start_ns        = span.start_ns,
        end_ns          = span.end_ns,
        duration_ms     = span.duration_ns / 1e6,
        attributes      = span.attributes,
    }))
end

return _M
