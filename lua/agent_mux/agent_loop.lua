-- agent_loop.lua  —  the multi-turn LLM ↔ tool loop.
--
-- Week 2: tool dispatch is wired in. When the model emits `tool_use`, we
-- run all the requested tools concurrently via tools.dispatcher, append
-- their results as the next user turn, and continue. Other stop_reasons
-- terminate as before.
--
-- A defensive `max_turns` guard keeps a misbehaving model from looping
-- forever; budget enforcement (token / wall-clock caps) lands in week 3
-- and replaces this guard.

local upstream   = require("agent_mux.upstream.anthropic")
local store      = require("agent_mux.session.store")
local registry   = require("agent_mux.tools.registry")
local dispatcher = require("agent_mux.tools.dispatcher")
local budget     = require("agent_mux.session.budget")
local metrics    = require("agent_mux.observability.metrics")
local log        = require("agent_mux.observability.log")
local errors     = require("agent_mux.errors")

local _M = {}
_M.__index = _M

-- Defensive cap. Real budgets land in week 3.
local MAX_TURNS = 16

function _M.new(session)
    return setmetatable({ session = session, _turns = 0 }, _M)
end

-- One iteration: call upstream, stream chunks, persist turn, return the
-- aggregated response so the caller can branch on stop_reason.
local function call_one_turn(self, sse, turn_n)
    local started_ms = ngx.now() * 1000

    sse:emit("turn_start", { turn = turn_n })

    local response, err = upstream.call(
        self.session.model,
        self.session.messages,
        -- Advertise our registered tools to the model. Empty array is
        -- fine; the upstream client elides it from the request.
        registry.to_api_schema(),
        {
            on_chunk = function(piece)
                sse:emit("model_chunk", { turn = turn_n, text = piece })
            end,
        }
    )

    if not response then
        return nil, err
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
    return response
end

function _M:run(sse)
    sse:emit("session_start", { session_id = self.session.id, model = self.session.model })
    metrics.inc("agent_mux_sessions_total", { status = "running" })

    while true do
        self._turns = self._turns + 1
        local turn_n = self._turns

        if turn_n > MAX_TURNS then
            log.warn("max_turns_exceeded", { session_id = self.session.id, max = MAX_TURNS })
            sse:emit("done", {
                stop_reason = "max_turns",
                turns       = turn_n - 1,
                note        = ("loop guard at %d turns"):format(MAX_TURNS),
            })
            store.complete(self.session, "max_turns")
            return
        end

        -- Cancellation check at turn boundary. If a DELETE /v1/sessions/:id
        -- arrived since the last turn, abort cleanly with a typed event.
        if store.is_cancel_requested(self.session) then
            sse:emit("cancelled", { turns = turn_n - 1 })
            store.cancel(self.session)
            store.clear_cancel_signal(self.session.id)
            metrics.inc("agent_mux_sessions_total", { status = "cancelled" })
            return
        end

        local response, err = call_one_turn(self, sse, turn_n)
        if not response then
            log.error("upstream_failed", { session_id = self.session.id, err = err })
            sse:emit("error", errors.to_sse_payload({
                code = "upstream_failed", message = err,
            }))
            store.error(self.session, err)
            metrics.inc("agent_mux_turns_total", {
                model = self.session.model, stop_reason = "error",
            })
            return
        end

        -- Budget enforcement: charge the just-finished turn against the
        -- session cap. If exceeded, terminate cleanly with a typed event
        -- — the model already produced output, so we honour this turn but
        -- refuse the next one.
        local turn_tokens = ((response.usage or {}).input_tokens  or 0)
                          + ((response.usage or {}).output_tokens or 0)
        local ok_budget, used, remaining = budget.try_consume(self.session, turn_tokens)
        if not ok_budget then
            sse:emit("done", {
                stop_reason = "budget_exhausted",
                turns       = turn_n,
                used_tokens = used,
                cap_tokens  = used + remaining,
            })
            store.complete(self.session, "budget_exhausted")
            return
        end

        local stop = response.stop_reason

        if stop == "end_turn" or stop == "stop_sequence" or stop == "max_tokens" then
            sse:emit("done", { stop_reason = stop, turns = turn_n })
            store.complete(self.session, stop)
            return
        end

        if stop == "tool_use" then
            local pending = upstream.tool_uses(response)
            if #pending == 0 then
                -- Defensive: stop_reason said tool_use but no blocks. Treat
                -- as terminal so we don't spin.
                sse:emit("done", {
                    stop_reason = "tool_use",
                    turns       = turn_n,
                    note        = "stop_reason=tool_use but no tool_use blocks present",
                })
                store.complete(self.session, "tool_use_empty")
                return
            end

            local results = dispatcher.run_concurrent(self.session, pending, sse)
            self.session:append_user_with_tool_results(results)
            local fok, ferr = store.flush(self.session)
            if not fok then
                log.warn("session_flush_failed", { session_id = self.session.id, err = ferr })
            end
            -- Continue the loop — next iteration sends the tool_results
            -- back upstream and the model produces its next turn.
        else
            log.warn("unknown_stop_reason", { stop_reason = stop, session_id = self.session.id })
            sse:emit("done", { stop_reason = stop or "unknown", turns = turn_n })
            store.complete(self.session, stop or "unknown")
            return
        end
    end
end

_M.MAX_TURNS = MAX_TURNS
return _M
