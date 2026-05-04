-- examples/tools/http_search/server.lua
--
-- A toy "search" service that AgentMux drives via tools/http.lua. Served
-- from the dev OpenResty under /mock/tools/search.
--
-- Contract: POST { "input": { "query": "..." } } → { "content": "..." }.
-- The "results" are canned per query so transcripts are deterministic in
-- the demo. Replace with a real backend (Tavily, Exa, your knowledge base)
-- by swapping this file.

local cjson = require("cjson.safe")

ngx.req.read_body()
local body = ngx.req.get_body_data() or ""
local req  = cjson.decode(body) or {}
local input = req.input or {}
local query = tostring(input.query or "")

-- Canned matches: keyword → answer. Anything not listed gets a generic
-- "no relevant hits" so the model handles a meaningful empty case.
local CANNED = {
    ["openresty"]   = "OpenResty is a full-fledged web platform built on top of nginx and LuaJIT.",
    ["dreamer"]     = "Dreamer is a model-based RL family from Hafner et al. that learns latent dynamics for imagination-based policy optimisation.",
    ["mujoco"]      = "MuJoCo is a physics engine widely used for robotics and continuous control benchmarks.",
    ["claude"]      = "Claude is the family of LLMs built by Anthropic; latest is Claude Opus 4.X.",
}

local function pick(q)
    local lower = q:lower()
    for kw, ans in pairs(CANNED) do
        if lower:find(kw, 1, true) then return ans end
    end
    return ("no relevant hits for %q (try: %s)"):format(q,
        "openresty / dreamer / mujoco / claude")
end

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode({
    content = pick(query),
}))
