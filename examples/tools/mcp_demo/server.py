#!/usr/bin/env python3
"""examples/tools/mcp_demo/server.py — minimal MCP stdio server.

Stdlib-only. Reads newline-delimited JSON-RPC 2.0 from stdin, writes
responses to stdout. Exposes two trivial tools so AgentMux's MCP client
has something concrete to drive at the end of week 3.

Tools:
    get_time     → returns the server's current UTC time as ISO-8601.
    echo         → returns whatever string was passed in `text`.

Spec reference: https://spec.modelcontextprotocol.io/

Run AgentMux with this server by adding to examples/tools/mcp_servers.json:

    {
      "servers": [
        {
          "name":    "demo",
          "command": "python3",
          "args":    ["examples/tools/mcp_demo/server.py"],
          "tool_prefix": "demo"
        }
      ]
    }
"""
from __future__ import annotations

import json
import sys
import datetime


PROTOCOL_VERSION = "2024-11-05"

TOOL_DEFS = [
    {
        "name":        "get_time",
        "description": "Return the current UTC time as an ISO-8601 string.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name":        "echo",
        "description": "Return the provided text unchanged. Useful for round-trip tests.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required":   ["text"],
        },
    },
]


def reply(req_id: object, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def err(req_id: object, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def text_block(s: str) -> dict:
    return {"type": "text", "text": s}


def handle_tools_call(req_id: object, params: dict) -> dict:
    name = params.get("name")
    args = params.get("arguments") or {}

    if name == "get_time":
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        return reply(req_id, {"content": [text_block(now)], "isError": False})

    if name == "echo":
        text = args.get("text", "")
        if not isinstance(text, str):
            return err(req_id, -32602, "echo: 'text' must be a string")
        return reply(req_id, {"content": [text_block(text)], "isError": False})

    return err(req_id, -32601, f"unknown tool: {name}")


def handle_request(msg: dict) -> dict | None:
    """Return a response dict, or None for notifications (no response)."""
    method  = msg.get("method")
    req_id  = msg.get("id")
    params  = msg.get("params") or {}

    # Notifications carry no id and expect no response.
    is_notification = req_id is None

    if method == "initialize":
        return reply(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities":    {"tools": {}},
            "serverInfo":      {"name": "agent_mux_demo_mcp", "version": "0.1"},
        })

    if method == "notifications/initialized":
        return None  # notification, ignore

    if method == "tools/list":
        return reply(req_id, {"tools": TOOL_DEFS})

    if method == "tools/call":
        return handle_tools_call(req_id, params)

    if is_notification:
        return None
    return err(req_id, -32601, f"method not found: {method}")


def main() -> None:
    # Line-buffered stdout so each response leaves immediately. AgentMux
    # reads newline-delimited; never write a partial line.
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue

        try:
            msg = json.loads(raw)
        except json.JSONDecodeError as exc:
            sys.stdout.write(json.dumps({
                "jsonrpc": "2.0", "id": None,
                "error":   {"code": -32700, "message": f"parse: {exc}"},
            }) + "\n")
            sys.stdout.flush()
            continue

        try:
            resp = handle_request(msg)
        except Exception as exc:    # noqa: BLE001
            resp = err(msg.get("id"), -32603, f"internal: {exc!r}")

        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
