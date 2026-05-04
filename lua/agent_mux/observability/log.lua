-- observability/log.lua  —  one-line structured log emission.
--
-- Why structured: every log line is a single JSON object. Any aggregator
-- (jq, fluentbit, Loki, Datadog) parses it without per-format parsers.
-- Why one line: nginx error_log expects line-delimited records.

local cjson = require("cjson.safe")

local _M = {}

local function emit(level, level_name, event, fields)
    fields = fields or {}
    fields.event = event
    fields.level = level_name
    fields.ts    = ngx.now()
    -- ngx.log writes one line; we attach the JSON as the message.
    ngx.log(level, cjson.encode(fields))
end

function _M.debug(event, fields) emit(ngx.DEBUG, "debug", event, fields) end
function _M.info(event, fields)  emit(ngx.INFO,  "info",  event, fields) end
function _M.warn(event, fields)  emit(ngx.WARN,  "warn",  event, fields) end
function _M.error(event, fields) emit(ngx.ERR,   "error", event, fields) end

return _M
