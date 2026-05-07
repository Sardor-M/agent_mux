#!/usr/bin/env bash
# Lumen PreToolUse hook — surfaces knowledge graph context before file searches.
# Fires on Glob and Grep tool calls in Claude Code.

TOOL_NAME="$1"

if [[ "$TOOL_NAME" == "Glob" || "$TOOL_NAME" == "Grep" ]]; then
    STATS=$(lumen status --json 2>/dev/null)
    if [[ $? -eq 0 && -n "$STATS" ]]; then
        SOURCES=$(echo "$STATS" | grep -o '"sources":[0-9]*' | cut -d: -f2)
        CONCEPTS=$(echo "$STATS" | grep -o '"concepts":[0-9]*' | cut -d: -f2)
        EDGES=$(echo "$STATS" | grep -o '"edges":[0-9]*' | cut -d: -f2)

        if [[ "$CONCEPTS" -gt 0 ]]; then
            echo "Lumen: Knowledge graph has $CONCEPTS concepts, $EDGES edges from $SOURCES sources."
            echo "Use the lumen MCP tools (search, query, god_nodes, communities) for structured lookup."
        fi
    fi
fi
