-- agent_loop.lua  —  the multi-turn LLM ↔ tool loop.
--
-- v0.1 (week 1) implements only the **turn-only** path: call upstream,
-- stream deltas to the client, persist the assistant turn, exit on any
-- non-`tool_use` stop_reason. When the model emits `tool_use`, we emit a
-- typed informational event and stop — tool dispatch is week 2.
--
-- The loop is the project's conceptual core. See docs/IMPLEMENTATION_PLAN.md §7.
-- Week 2 will plug `tools.dispatcher` into the `tool_use` branch; week 3 adds
-- per-tool rate-limit, hooks, cancellation. Keep the surface stable.

local upstream  = require("agent_mux.upstream.anthropic")
local store     = require("agent_mux.session.store")
local metrics   = require("agent_mux.observability.metrics")
local log       = require("agent_mux.observability.log")
local errors    = require("agent_mux.errors")

local _M = {}
_M.__index = _M

function _M.new(session)
    return setmetatable({ session = session, _turns = 0 }, _M)
end

-- Run the loop. `sse` is a transport/sse.lua writer.
function _M:run(sse)
    sse:emit("session_start", { session_id = self.session.id, model = self.session.model })
    metrics.inc("agent_mux_sessions_total", { status = "running" })

    while true do
        self._turns = self._turns + 1
        local turn_n = self._turns
        local started_ms = ngx.now() * 1000

        sse:emit("turn_start", { turn = turn_n })

        local response, err = upstream.call(
            self.session.model,
            self.session.messages,
            self.session.tools,
            {
                on_chunk = function(piece)
                    sse:emit("model_chunk", { turn = turn_n, text = piece })
                end,
            }
        )

        if not response then
            log.error("upstream_failed", { session_id = self.session.id, err = err })
            sse:emit("error", errors.to_sse_payload({
                code    = "upstream_failed",
                message = err,
            }))
            store.error(self.session, err)
            metrics.inc("agent_mux_turns_total", {
                model = self.session.model, stop_reason = "error",
            })
            return
        end

        self.session:append_assistant(response)
        local ok, ferr = store.flush(self.session)
        if not ok then
            log.warn("session_flush_failed", { session_id = self.session.id, err = ferr })
        end

        sse:emit("turn_complete", {
            turn        = turn_n,
            stop_reason = response.stop_reason,
            usage       = response.usage,
            latency_ms  = ngx.now() * 1000 - started_ms,
        })
        metrics.inc("agent_mux_turns_total", {
            model = self.session.model, stop_reason = response.stop_reason or "unknown",
        })
        if response.usage then
            metrics.inc("agent_mux_tokens_total",
                { direction = "input",  model = self.session.model },
                response.usage.input_tokens or 0)
            metrics.inc("agent_mux_tokens_total",
                { direction = "output", model = self.session.model },
                response.usage.output_tokens or 0)
        end

        local stop = response.stop_reason

        if stop == "end_turn" or stop == "stop_sequence" or stop == "max_tokens" then
            sse:emit("done", { stop_reason = stop, turns = turn_n })
            store.complete(self.session, stop)
            return
        end

        if stop == "tool_use" then
            -- Week 2 will dispatch here; for now, surface what we'd run and stop.
            local pending = upstream.tool_uses(response)
            sse:emit("done", {
                stop_reason   = "tool_use",
                turns         = turn_n,
                pending_tools = pending,
                note          = "tool dispatch arrives in week 2 — see docs/IMPLEMENTATION_PLAN.md §8",
            })
            store.complete(self.session, "tool_use_pending")
            return
        end

        -- Defensive: an unknown stop_reason shouldn't loop forever. Treat
        -- as terminal so a bug in upstream parsing can't run away.
        log.warn("unknown_stop_reason", { stop_reason = stop, session_id = self.session.id })
        sse:emit("done", { stop_reason = stop or "unknown", turns = turn_n })
        store.complete(self.session, stop or "unknown")
        return
    end
end

return _M
