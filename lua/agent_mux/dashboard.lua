-- dashboard.lua  —  self-contained ops dashboard served on 127.0.0.1:7100.
--
-- agent_mux runs as a single OpenResty process; this module adds a small web
-- UI (one HTML page + a few JSON/text endpoints) on a dedicated localhost port
-- so you can watch the supervised MCP fleet, recent errors, and tool traffic
-- without tailing logs. Wired up by the `server { listen 127.0.0.1:7100; }`
-- block in conf/nginx.conf.
--
-- Endpoints (all same-origin, so the page needs no CORS):
--   GET /            → the dashboard page
--   GET /api/health  → { ok, worker_pid, redis_up }
--   GET /api/status  → server.mcp_status() (MCP fleet)
--   GET /api/logs    → tail of logs/error.log (text)
--   GET /api/metrics → Prometheus exposition (reused)

local cjson = require("cjson.safe")

local _M = {}

local LOG_PATH      = "logs/error.log"
local LOG_TAIL_BYTES = 256 * 1024   -- only read the last chunk of the log

-- GET /api/health
function _M.health()
    local redis_up = false
    local ok, rc = pcall(require, "agent_mux.redis_client")
    if ok then
        local r = rc.connect()
        if r then
            local pong = r:ping()
            redis_up = pong ~= nil and pong ~= false
            rc.release(r)
        end
    end
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        ok         = true,
        worker_pid = (ngx.worker and ngx.worker.pid and ngx.worker.pid()) or nil,
        redis_up   = redis_up,
    }))
end

-- Drop nginx connection-churn noise that drowns out the useful lines.
local function is_noise(line)
    return line:find("closed keepalive connection", 1, true) ~= nil
        or line:find("kevent%(%) reported") ~= nil
        or line:find("SSL_", 1, true) ~= nil
end

local function want_line(line, level)
    if is_noise(line) then return false end
    if level == "all" then return true end
    local is_err = line:find("%[error%]") or line:find("%[crit%]")
                or line:find("%[alert%]") or line:find("%[emerg%]")
    if level == "error" then return is_err ~= nil end
    if level == "warn"  then return (is_err or line:find("%[warn%]")) ~= nil end
    return true
end

-- GET /api/logs?n=300&level=all|warn|error
function _M.logs()
    local args  = ngx.req.get_uri_args()
    local n     = math.min(tonumber(args.n) or 300, 2000)
    local level = args.level or "all"

    ngx.header["Content-Type"] = "text/plain; charset=utf-8"

    local f = io.open(LOG_PATH, "rb")
    if not f then
        ngx.say("(no log file yet at " .. LOG_PATH .. ")")
        return
    end
    local size = f:seek("end") or 0
    if size > LOG_TAIL_BYTES then f:seek("set", size - LOG_TAIL_BYTES) else f:seek("set", 0) end
    local blob = f:read("*a") or ""
    f:close()

    local lines = {}
    for line in (blob .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and want_line(line, level) then
            lines[#lines + 1] = line
        end
    end
    local from = math.max(1, #lines - n + 1)
    local out  = {}
    for i = from, #lines do out[#out + 1] = lines[i] end
    ngx.say(table.concat(out, "\n"))
end

-- GET /  — the page. Self-contained: inline CSS + JS, polls the /api/* routes.
function _M.page()
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say([==[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>agent_mux · dashboard</title>
<style>
  :root{
    --bg:#0b0f14; --panel:#111823; --panel2:#0e141d; --line:#1f2a37;
    --text:#e6edf3; --dim:#8b98a9; --green:#3fb950; --red:#f85149;
    --amber:#d29922; --blue:#58a6ff; --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
    font:14px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif}
  a{color:var(--blue)}
  header{display:flex;align-items:center;gap:14px;flex-wrap:wrap;
    padding:16px 22px;border-bottom:1px solid var(--line);background:var(--panel2)}
  .brand{font-weight:700;letter-spacing:.3px;font-size:16px}
  .brand b{color:var(--blue)}
  .pill{display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:999px;
    font-size:12px;font-weight:600;border:1px solid var(--line);background:var(--panel)}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--dim);box-shadow:0 0 0 0 rgba(0,0,0,0)}
  .dot.ok{background:var(--green);box-shadow:0 0 8px var(--green)}
  .dot.bad{background:var(--red);box-shadow:0 0 8px var(--red)}
  .spacer{flex:1}
  .muted{color:var(--dim);font-size:12px}
  main{max-width:1080px;margin:0 auto;padding:22px}
  .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:20px}
  .stat{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
  .stat .k{color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.5px}
  .stat .v{font:600 26px/1.2 var(--mono);margin-top:4px}
  .v.bad{color:var(--red)} .v.warn{color:var(--amber)} .v.ok{color:var(--green)}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;margin-bottom:20px;overflow:hidden}
  .card h2{margin:0;padding:13px 18px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;
    color:var(--dim);border-bottom:1px solid var(--line);display:flex;align-items:center;gap:10px}
  table{width:100%;border-collapse:collapse;font:13px/1.4 var(--mono)}
  th,td{text-align:left;padding:10px 18px;border-bottom:1px solid var(--line);white-space:nowrap}
  th{color:var(--dim);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.5px}
  tr:last-child td{border-bottom:0}
  td.num{text-align:right}
  .tag{display:inline-flex;align-items:center;gap:6px;font-weight:600}
  .empty{padding:22px 18px;color:var(--dim)}
  .logbar{display:flex;gap:8px;align-items:center;padding:10px 18px;border-bottom:1px solid var(--line);flex-wrap:wrap}
  .seg{display:flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
  .seg button{background:transparent;color:var(--dim);border:0;padding:6px 12px;font-size:12px;cursor:pointer}
  .seg button.on{background:var(--blue);color:#08111f;font-weight:700}
  input.search{flex:1;min-width:120px;background:var(--panel2);border:1px solid var(--line);
    color:var(--text);border-radius:8px;padding:6px 10px;font:12px var(--mono)}
  pre.log{margin:0;max-height:46vh;overflow:auto;padding:12px 18px;font:12px/1.55 var(--mono);
    background:var(--panel2);white-space:pre-wrap;word-break:break-word}
  pre.log .e{color:var(--red)} pre.log .w{color:var(--amber)} pre.log .i{color:var(--dim)}
  .toggle{cursor:pointer;user-select:none}
</style>
</head>
<body>
<header>
  <span class="brand">⬢ agent<b>_mux</b></span>
  <span id="health" class="pill"><span class="dot"></span><span>connecting…</span></span>
  <span id="redis" class="pill"><span class="dot"></span><span>redis</span></span>
  <span class="spacer"></span>
  <span class="muted">worker <span id="pid">—</span></span>
  <span class="pill toggle" id="auto"><span class="dot ok"></span><span>auto 3s</span></span>
  <span class="muted">updated <span id="updated">—</span></span>
</header>
<main>
  <div class="grid">
    <div class="stat"><div class="k">MCP servers</div><div class="v" id="s-servers">—</div></div>
    <div class="stat"><div class="k">Up</div><div class="v ok" id="s-up">—</div></div>
    <div class="stat"><div class="k">Tool calls</div><div class="v" id="s-calls">—</div></div>
    <div class="stat"><div class="k">Errors</div><div class="v" id="s-errors">—</div></div>
  </div>

  <div class="card">
    <h2>MCP fleet</h2>
    <div id="fleet"><div class="empty">loading…</div></div>
  </div>

  <div class="card">
    <h2>Tool calls <span class="muted" style="text-transform:none;letter-spacing:0">/metrics</span></h2>
    <div id="tools"><div class="empty">loading…</div></div>
  </div>

  <div class="card">
    <h2>Logs</h2>
    <div class="logbar">
      <div class="seg" id="lvl">
        <button data-l="all" class="on">All</button>
        <button data-l="warn">Warn+</button>
        <button data-l="error">Errors</button>
      </div>
      <input class="search" id="search" placeholder="filter lines…">
      <span class="muted" id="logmeta"></span>
    </div>
    <pre class="log" id="log">loading…</pre>
  </div>
  <p class="muted">Read-only. Fleet CLI: <code>make status</code> · live: <code>make watch</code></p>
</main>
<script>
const $ = s => document.querySelector(s);
let auto = true, level = 'all', search = '', logText = '';

function esc(s){ return s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function n(v){ return (v==null?0:v).toLocaleString(); }

async function jget(u){ const r = await fetch(u); if(!r.ok) throw new Error(u); return r.json(); }
async function tget(u){ const r = await fetch(u); if(!r.ok) throw new Error(u); return r.text(); }

function setHealth(ok, redisUp, pid){
  const h = $('#health'); h.querySelector('.dot').className = 'dot ' + (ok?'ok':'bad');
  h.querySelector('span:last-child').textContent = ok ? 'healthy' : 'unreachable';
  const r = $('#redis'); r.querySelector('.dot').className = 'dot ' + (redisUp?'ok':'bad');
  r.querySelector('span:last-child').textContent = redisUp ? 'redis up' : 'redis down';
  $('#pid').textContent = pid ?? '—';
}

function renderFleet(servers){
  let calls=0, errors=0, up=0;
  servers.forEach(s => { calls+=s.calls_total||0; errors+=s.errors_total||0; if(s.alive) up++; });
  $('#s-servers').textContent = servers.length;
  $('#s-up').textContent = up + '/' + servers.length;
  $('#s-up').className = 'v ' + (up===servers.length ? 'ok' : (up===0?'bad':'warn'));
  $('#s-calls').textContent = n(calls);
  $('#s-errors').textContent = n(errors);
  $('#s-errors').className = 'v ' + (errors>0?'bad':'ok');

  if(!servers.length){ $('#fleet').innerHTML = '<div class="empty">No MCP servers configured. Set <code>AGENT_MUX_MCP_FILE</code> and restart.</div>'; return; }
  const rows = servers.map(s => {
    const dot = s.alive ? 'ok' : 'bad';
    const st  = s.alive ? 'up' : 'DOWN';
    const rc  = (s.restarts>0) ? `<span class="v warn" style="font-size:13px">${s.restarts}</span>` : '0';
    const er  = (s.errors_total>0) ? `<span class="v bad" style="font-size:13px">${n(s.errors_total)}</span>` : '0';
    const lat = (s.last_latency_ms!=null) ? s.last_latency_ms.toFixed(1) : '—';
    return `<tr>
      <td><span class="tag"><span class="dot ${dot}"></span>${esc(s.name)}</span></td>
      <td>${st}</td>
      <td class="num">${s.pid ?? '—'}</td>
      <td class="num">${rc}</td>
      <td class="num">${s.tool_count||0}</td>
      <td class="num">${s.in_flight||0}</td>
      <td class="num">${n(s.calls_total)}</td>
      <td class="num">${er}</td>
      <td class="num">${lat}</td>
    </tr>`;
  }).join('');
  $('#fleet').innerHTML = `<table><thead><tr>
    <th>Server</th><th>Status</th><th>PID</th><th>Restarts</th><th>Tools</th>
    <th>In&nbsp;flight</th><th>Calls</th><th>Errors</th><th>Last&nbsp;ms</th>
  </tr></thead><tbody>${rows}</tbody></table>`;
}

function renderTools(metricsText){
  const re = /^agent_mux_tool_calls_total\{([^}]*)\}\s+(\d+)/gm;
  const rows = []; let m;
  while((m = re.exec(metricsText))){
    const lbl = {}; m[1].split(',').forEach(kv=>{ const i=kv.indexOf('='); if(i>0) lbl[kv.slice(0,i)]=kv.slice(i+1).replace(/"/g,''); });
    rows.push({name:lbl.name||'?', outcome:lbl.outcome||'?', v:+m[2]});
  }
  if(!rows.length){ $('#tools').innerHTML = '<div class="empty">No tool calls yet.</div>'; return; }
  rows.sort((a,b)=> b.v-a.v);
  $('#tools').innerHTML = `<table><thead><tr><th>Tool</th><th>Outcome</th><th>Count</th></tr></thead><tbody>${
    rows.map(r=>`<tr><td>${esc(r.name)}</td><td>${r.outcome==='ok'
      ? '<span class="tag"><span class="dot ok"></span>ok</span>'
      : '<span class="tag"><span class="dot bad"></span>'+esc(r.outcome)+'</span>'}</td><td class="num">${n(r.v)}</td></tr>`).join('')
  }</tbody></table>`;
}

function renderLog(){
  let lines = logText.split('\n');
  if(search){ const q = search.toLowerCase(); lines = lines.filter(l => l.toLowerCase().includes(q)); }
  const html = lines.map(l => {
    let cls = 'i';
    if(/\[(error|crit|alert|emerg)\]/.test(l)) cls='e';
    else if(/\[warn\]/.test(l)) cls='w';
    else cls='';
    return `<span class="${cls}">${esc(l)}</span>`;
  }).join('\n');
  const el = $('#log'); const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  el.innerHTML = html || '(no matching lines)';
  $('#logmeta').textContent = lines.length + ' lines';
  if(atBottom) el.scrollTop = el.scrollHeight;
}

async function refresh(){
  try {
    const [health, status] = await Promise.all([jget('/api/health'), jget('/api/status')]);
    setHealth(true, health.redis_up, health.worker_pid);
    renderFleet(status.servers || []);
    try { renderTools(await tget('/api/metrics')); } catch(e){}
    logText = await tget('/api/logs?n=400&level=' + level);
    renderLog();
    $('#updated').textContent = new Date().toLocaleTimeString();
  } catch(e){
    setHealth(false, false, '—');
  }
}

$('#lvl').addEventListener('click', e => {
  const b = e.target.closest('button'); if(!b) return;
  level = b.dataset.l;
  [...$('#lvl').children].forEach(x => x.classList.toggle('on', x===b));
  refresh();
});
$('#search').addEventListener('input', e => { search = e.target.value; renderLog(); });
$('#auto').addEventListener('click', () => {
  auto = !auto;
  $('#auto').querySelector('.dot').className = 'dot ' + (auto?'ok':'');
  $('#auto').querySelector('span:last-child').textContent = auto ? 'auto 3s' : 'paused';
});

refresh();
setInterval(() => { if(auto) refresh(); }, 3000);
</script>
</body>
</html>]==])
end

return _M
