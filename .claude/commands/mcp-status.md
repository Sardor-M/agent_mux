---
description: Show agent_mux supervised MCP server status
allowed-tools: Bash(bash scripts/agent-mux-status.sh)
---

Run `bash scripts/agent-mux-status.sh` and report the supervised MCP server
fleet: which servers are up vs DOWN, their restart counts, in-flight calls,
total calls/errors, and last-call latency.

Call out anything that needs attention — a DOWN server, a climbing restart
count (crash-looping), or a rising error total — and otherwise confirm the
fleet is healthy in one line.
