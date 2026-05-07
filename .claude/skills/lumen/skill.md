---
name: lumen-brain
description: Always-on knowledge brain. Fires on every message to check memory first and capture new knowledge after.
triggers:
  - every message
alwaysOn: true
---

# Lumen Brain Protocol

You have a persistent knowledge brain via Lumen MCP tools.
Follow this protocol on EVERY message — not only when the user explicitly mentions Lumen.

## Step 1 — Brain-first lookup (before answering)

On every substantive question or research task:

1. Call `brain_ops` with the core topic of the question.
2. If results exist — use them as grounding context in your answer.
3. **Always cite the source name** when using KB content. Format: [Source: title] at the end of each claim grounded in the KB. The source title comes from the `source_title` field in search results.
4. Say "not in your knowledge base yet" only when `brain_ops` returns `found: false`.

Never answer a knowledge question from training alone. Always check first.
Always distinguish between "from your knowledge base" and "from my training data" when answering.

Intent shortcuts — call the right tool directly:

| What the user says | Tool |
|---|---|
| "who is X" / "what is X" | `brain_ops` with intent `concept` |
| "how does X connect to Y" / "path from X to Y" | `brain_ops` with intent `path`, from + to filled |
| "what is related to X" / "neighbors of X" | `brain_ops` with intent `neighborhood` |
| "what are my main topics" / "top concepts" | `god_nodes` then `communities` |
| "add this URL / file / paper" | `add` — ingest immediately, then call `compile` to extract concepts |
| "compile" / "extract concepts" | `compile` — runs LLM extraction on unprocessed sources |
| "remember this" / "capture this" / "save this" | `capture` with the user's exact phrasing |

## Step 2 — Passive signal capture (after responding)

After every response where any of the following happened, call `capture`:

- The user stated an original idea, observation, or thesis
- You explained a non-trivial concept the user will want to recall later
- A person, project, paper, or company was mentioned with meaningful context

Rules for capture:
- Preserve the user's **exact phrasing** — do not paraphrase or improve it
- Set `type` to `idea` for original thinking, `fact` for external facts, `entity_mention` for people/companies
- Include `related_slugs` if you know which existing concepts this connects to

## Step 3 — End-of-session summary

When a long conversation ends (user says "thanks", "bye", or closes topic), call `session_summary` with:
- A brief summary of what was discussed
- All concept slugs that came up

## Tool quick reference

| Tool | When to call |
|---|---|
| `brain_ops` | Before answering any knowledge question |
| `capture` | After any response that contains new knowledge |
| `session_summary` | When a session ends |
| `add` | When user provides a URL, file, or content to ingest |
| `compile` | After `add` — extracts concepts and edges from new sources via LLM |
| `search` | Direct keyword search when brain_ops is too broad |
| `concept` | Get full compiled truth + timeline for a specific concept |
| `backlinks` | Find what else references a concept |
| `add_link` | Manually cross-link two concepts |
| `neighbors` | N-hop neighborhood around a concept |
| `path` | Shortest connection between two concepts |
| `god_nodes` | Most connected concepts — good for orientation |
| `communities` | Topic clusters in the knowledge graph |
| `status` | Show KB statistics |
