#!/usr/bin/env bash
# =============================================================================
# e2e-smoke.sh — dsh-ecom 端到端冒烟：装包 → MCP stdio 真跑一次 → 产物落工作区
#
# 用法：
#   bash e2e-smoke.sh            # 跑完清掉临时工作区（会话先删）
#   bash e2e-smoke.sh --keep     # 保留临时工作区，便于事后看现场
#
# 环境变量：
#   GATEWAY_URL    默认 http://127.0.0.1:19671
#   GATEWAY_TOKEN  必填（可回退 DSH_SECRET_GATEWAY_TOKEN）；只经环境变量传给子进程，
#                  不进 argv、不落文件、不打印（长度 < 32 只 WARN，建议换 openssl rand -hex 32）
#   E2E_ACCOUNT    默认 e2e-smoke（台账按 account 主键 upsert，重复跑不新增行）
#
# 流程：mktemp 工作区 → L1 → L2 → L3(amazon + ebay) → stdio 起 farm/mcp/farm-mcp.js
#       initialize → tools/list(7) → farm_health(ok:true) → farm_session_create
#       → farm_task goto（唯一 query URL）→ farm_task eval（transferSize 验真上网）
#       → farm_task extract title
#       → farm_session_delete → 写 95-engine/smoke/report.json 并断言字段。
#
# 边界：只写 mktemp 工作区；farm 只新增/更新一行默认租户会话（收尾删除，台账保留）。
# 硬闸：网关探不通直接 FAIL（与 verify.sh 的 WARN 口径不同）。
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（可用 --keep）" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); echo "  PASS $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
warn() { WARN=$((WARN+1)); echo "  WARN $*"; }

TMP="$(mktemp -d /tmp/dsh-ecom-e2e.XXXXXX)" || { echo "FAIL 无法创建临时目录"; exit 2; }
WS="$TMP/workspace"
cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    echo
    echo "临时工作区保留：$WS"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
TOKEN="${GATEWAY_TOKEN:-${DSH_SECRET_GATEWAY_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  echo "FAIL GATEWAY_TOKEN 未设置（也可用 DSH_SECRET_GATEWAY_TOKEN）"
  exit 2
fi
export GATEWAY_TOKEN="$TOKEN"
TOKEN_LEN=${#TOKEN}

echo "== dsh-ecom e2e 冒烟 =="
echo "仓库：$ROOT"
echo "网关：$GATEWAY_URL"
echo "临时工作区：$WS"

# ---------------------------------------------------------------- 0. 网关硬闸
echo "-- 0. 网关硬闸（探不通直接 FAIL）"
[ "$TOKEN_LEN" -ge 32 ] || warn "GATEWAY_TOKEN 长度 $TOKEN_LEN < 32（建议 openssl rand -hex 32；本次照跑）"
HCODE="$(curl -sS --max-time 5 -o "$TMP/health.json" -w '%{http_code}' "${GATEWAY_URL%/}/v1/health" 2>/dev/null || true)"
if [ "$HCODE" = "200" ]; then
  ok "网关可达（${GATEWAY_URL%/}/v1/health 200）"
else
  bad "网关不可达或未就绪（${GATEWAY_URL%/}/v1/health HTTP=${HCODE:-000}）"
  echo
  echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
  echo "RESULT: NOT_READY（网关硬闸未过，后续未跑）"
  exit 1
fi

# ---------------------------------------------------------------- 1. 边界快照
echo "-- 1. 边界快照"
REAL_WS="$HOME/ds-bot-workspace"
REAL_MTIME=""
if [ -d "$REAL_WS" ]; then
  REAL_MTIME="$(stat -f %m "$REAL_WS" 2>/dev/null || stat -c %Y "$REAL_WS" 2>/dev/null || true)"
  [ -n "$REAL_MTIME" ] && ok "真工作区 mtime 快照（$REAL_MTIME）" || warn "读不到真工作区 mtime，跳过边界校验"
else
  warn "本机没有 ~/ds-bot-workspace，跳过边界校验"
fi
FARM_DIRTY1="$(git -C "$ROOT" status --porcelain farm | wc -l | tr -d ' ')"
[ "$FARM_DIRTY1" -eq 0 ] && ok "farm/ 改动 0 行（跑前）" || warn "farm/ 跑前已有 $FARM_DIRTY1 行改动（不归本次，跑后仍按 0 断言）"

# ---------------------------------------------------------------- 2. 装三层
echo "-- 2. 安装三层（L1 → L2 → L3 amazon/ebay）"
install_pkg() {
  local label="$1" expect="$2"; shift 2
  local out rc w
  out="$("$@" 2>&1)"; rc=$?
  w="$(printf '%s\n' "$out" | sed -n 's/^== 汇总: write=\([0-9]*\) skip=\([0-9]*\) fail=\([0-9]*\) ==/\1 \2 \3/p' | tail -1)"
  if [ "$rc" -eq 0 ] && [ "$w" = "$expect" ]; then
    ok "$label（write/skip/fail=$w）"
  else
    bad "$label（rc=$rc 汇总='${w:-无}'）"
    printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
  fi
}
install_pkg "L1 安装" "1 0 0" bash "$SRC/l1/install.sh" "$WS"
install_pkg "L2 安装" "53 0 0" bash "$SRC/l2/install.sh" "$WS"
install_pkg "L3 amazon 安装" "4 0 0" bash "$SRC/l3/install.sh" amazon "$WS"
install_pkg "L3 ebay 安装" "4 0 0" bash "$SRC/l3/install.sh" ebay "$WS"
[ -f "$WS/.dsh/ecom-l1.json" ] && ok "L1 标记文件存在" || bad "L1 标记文件缺失"
[ -f "$WS/95-engine/platforms/amazon/manifest.json" ] && ok "L3 amazon 落点存在" || bad "L3 amazon 落点缺失"
[ -f "$WS/95-engine/platforms/ebay/manifest.json" ] && ok "L3 ebay 落点存在" || bad "L3 ebay 落点缺失"

# ---------------------------------------------------------------- 3. MCP stdio
echo "-- 3. MCP stdio 真跑（health → create → goto → extract → delete）"
mkdir -p "$WS/95-engine/smoke"
E2E_WORKSPACE="$WS" E2E_MCP="$ROOT/farm/mcp/farm-mcp.js" E2E_NODE="$(command -v node)" \
E2E_ACCOUNT="${E2E_ACCOUNT:-e2e-smoke}" GATEWAY_URL="$GATEWAY_URL" node - <<'NODE'
'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const WS = process.env.E2E_WORKSPACE || '';
const MCP = process.env.E2E_MCP || '';
const NODE = process.env.E2E_NODE || process.execPath;
const ACCOUNT = process.env.E2E_ACCOUNT || 'e2e-smoke';
const GATEWAY_URL = process.env.GATEWAY_URL || 'http://127.0.0.1:19671';
const REPORT = path.join(WS, '95-engine', 'smoke', 'report.json');

const checks = [];
const report = {
  generated_at: new Date().toISOString(),
  account: ACCOUNT,
  gateway: { url: GATEWAY_URL, version: null, health_ok: null },
  mcp: { path: MCP, server: null, version: null, protocol: null },
  tool_count: 0,
  tool_names: [],
  health_ok: null,
  session: { account: ACCOUNT, session_id: null, created: false, deleted: false, status: null, data_retained: null },
  goto: { ok: null, url: null, readyState: null },
  nav: { transfer_size: null, decoded_body_size: null, duration: null, cache_hit: null },
  extract: { ok: null, selector_map: { title: 'title' }, fields: null, missing: null },
  title: null,
};

function addCheck(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail: detail || null });
  if (!ok) console.error('  [mcp] FAIL ' + name + (detail ? '：' + detail : ''));
}

function writeReport() {
  report.checks = checks;
  fs.mkdirSync(path.dirname(REPORT), { recursive: true });
  fs.writeFileSync(REPORT, JSON.stringify(report, null, 2) + '\n');
}

function client(child) {
  const pending = new Map();
  let nextId = 1;
  const rl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  rl.on('line', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch (e) { return; }
    if (msg && msg.id !== undefined && pending.has(msg.id)) {
      const p = pending.get(msg.id);
      clearTimeout(p.timer);
      pending.delete(msg.id);
      if (msg.error) p.reject(new Error('JSON-RPC error: ' + JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    }
  });
  child.on('exit', (code) => {
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error('MCP 进程退出 code=' + code));
      pending.delete(id);
    }
  });
  return {
    request(method, params, timeoutMs) {
      const id = nextId++;
      const tmo = timeoutMs || 120000;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('请求超时 ' + method)); }, tmo);
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
    },
    notify(method, params) {
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
    },
  };
}

async function callTool(mcp, name, args) {
  const res = await mcp.request('tools/call', { name, arguments: args || {} }, 150000);
  const txt = (res && res.content && res.content[0] && res.content[0].text) || '';
  let data = null;
  try { data = JSON.parse(txt); } catch (e) { data = null; }
  return { isError: !!(res && res.isError), text: txt, data };
}

(async () => {
  let child = null;
  let mcp = null;
  let sessionId = null;
  let created = false;
  let deleted = false;
  let exitCode = 0;
  try {
    console.error('  → initialize');
    child = spawn(NODE, [MCP], {
      stdio: ['pipe', 'pipe', 'inherit'],
      env: Object.assign({}, process.env, { GATEWAY_URL }),
    });
    mcp = client(child);

    const init = await mcp.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'dsh-e2e-smoke', version: '0.1.0' },
    });
    report.mcp.protocol = (init && init.protocolVersion) || null;
    report.mcp.server = (init && init.serverInfo && init.serverInfo.name) || null;
    report.mcp.version = (init && init.serverInfo && init.serverInfo.version) || null;
    addCheck('initialize 握手', report.mcp.server === 'farm-gateway' && !!report.mcp.protocol,
      report.mcp.server + ' ' + report.mcp.version + ' protocol=' + report.mcp.protocol);
    mcp.notify('notifications/initialized', {});

    console.error('  → tools/list');
    const list = await mcp.request('tools/list', {});
    const tools = (list && list.tools) || [];
    report.tool_count = tools.length;
    report.tool_names = tools.map((t) => t.name).sort();
    addCheck('tools/list 断言 7 个工具', tools.length === 7,
      '实际 ' + tools.length + '：' + report.tool_names.join(','));

    console.error('  → farm_health');
    const health = await callTool(mcp, 'farm_health', {});
    report.gateway.health_ok = !!(health.data && health.data.ok === true);
    report.gateway.version = (health.data && health.data.version) || null;
    report.health_ok = report.gateway.health_ok;
    addCheck('farm_health ok:true', report.health_ok === true,
      'version=' + report.gateway.version + ' text=' + String(health.text || '').slice(0, 160));

    console.error('  → farm_session_create（account=' + ACCOUNT + '）');
    const create = await callTool(mcp, 'farm_session_create', { account: ACCOUNT, engine: 'chromium', platform: 'e2e' });
    const cdata = create.data || {};
    sessionId = cdata.session_id || null;
    created = !!sessionId && cdata.ok !== false;
    report.session.session_id = sessionId;
    report.session.created = created;
    addCheck('farm_session_create', created, 'session_id=' + sessionId + ' status=' + (cdata.status || '-'));

    if (created) {
      /* 唯一 query：example.com 带 max-age=86000，固定 URL 会吃 profile 磁盘缓存（transferSize=0） */
      const GOTO_URL = 'https://example.com/?e2e-smoke=' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
      console.error('  → farm_task goto（cache-bust）');
      const goto = await callTool(mcp, 'farm_task', {
        session_id: sessionId, type: 'goto',
        params: { url: GOTO_URL }, wait_ms: 60000,
      });
      const g = goto.data || {};
      report.goto.ok = g.status === 'succeeded' && !!(g.result && g.result.ok === true);
      report.goto.url = (g.result && g.result.url) || null;
      report.goto.readyState = (g.result && g.result.readyState) || null;
      addCheck('farm_task goto（cache-bust URL）', report.goto.ok === true,
        'status=' + (g.status || '-') + ' url=' + report.goto.url + ' readyState=' + report.goto.readyState);

      /* 真上网断言：缓存命中时 transferSize=0，堵住「goto succeeded 但其实没联网」 */
      console.error('  → farm_task eval（navigation transferSize）');
      const navExpr = "(() => { const es = performance.getEntriesByType('navigation'); const n = es && es[0]; return { has_entry: !!n, transfer_size: n ? n.transferSize : null, decoded_body_size: n ? n.decodedBodySize : null, duration: n ? Math.round(n.duration) : null, cache_hit: !(n && n.transferSize > 0) }; })()";
      const nav = await callTool(mcp, 'farm_task', {
        session_id: sessionId, type: 'eval',
        params: { expr: navExpr }, wait_ms: 60000,
      });
      const nv = (nav.data && nav.data.result) || {};
      report.nav.transfer_size = nv.transfer_size === undefined ? null : nv.transfer_size;
      report.nav.decoded_body_size = nv.decoded_body_size === undefined ? null : nv.decoded_body_size;
      report.nav.duration = nv.duration === undefined ? null : nv.duration;
      report.nav.cache_hit = nv.cache_hit === undefined ? null : nv.cache_hit;
      const netOk = nv.cache_hit === false && typeof nv.transfer_size === 'number' && nv.transfer_size > 0;
      addCheck('页面真上网（transferSize>0）', netOk,
        'transfer_size=' + report.nav.transfer_size + ' decoded_body_size=' + report.nav.decoded_body_size +
        ' duration_ms=' + report.nav.duration + ' cache_hit=' + report.nav.cache_hit);

      console.error('  → farm_task extract（selector_map.title=title）');
      const ext = await callTool(mcp, 'farm_task', {
        session_id: sessionId, type: 'extract',
        params: { selector_map: { title: 'title' } }, wait_ms: 60000,
      });
      const e = ext.data || {};
      report.extract.ok = e.status === 'succeeded' && !!(e.result && e.result.ok === true);
      report.extract.fields = (e.result && e.result.fields) || null;
      report.extract.missing = (e.result && e.result.missing) || null;
      report.title = (e.result && e.result.fields && e.result.fields.title) || null;
      addCheck('farm_task extract 取 title', !!(report.title && String(report.title).trim()),
        'title=' + JSON.stringify(report.title) + ' missing=' + JSON.stringify(report.extract.missing));

      console.error('  → farm_session_delete');
      const del = await callTool(mcp, 'farm_session_delete', { session_id: sessionId });
      const d = del.data || {};
      deleted = !del.isError && d.ok === true;
      report.session.deleted = deleted;
      report.session.status = d.status || null;
      report.session.data_retained = d.data_retained === undefined ? null : d.data_retained;
      addCheck('farm_session_delete', deleted,
        'status=' + report.session.status + ' data_retained=' + report.session.data_retained);
    }
  } catch (err) {
    addCheck('MCP 链路', false, String((err && err.message) || err));
  } finally {
    if (created && !deleted && mcp) {
      try {
        const del = await callTool(mcp, 'farm_session_delete', { session_id: sessionId });
        const d = del.data || {};
        deleted = !del.isError && d.ok === true;
        report.session.deleted = deleted;
        report.session.status = d.status || report.session.status;
        report.session.data_retained = d.data_retained === undefined ? null : d.data_retained;
        addCheck('兜底 farm_session_delete', deleted, 'session_id=' + sessionId);
      } catch (e2) {
        addCheck('兜底 farm_session_delete', false, String((e2 && e2.message) || e2));
      }
    }
    if (checks.some((c) => !c.ok)) exitCode = 1;
    try { writeReport(); } catch (e3) { console.error('  [mcp] FAIL 写 report.json：' + e3.message); exitCode = 1; }
    if (child) { try { child.stdin.end(); } catch (e) {} }
    setTimeout(() => process.exit(exitCode), 300);
  }
})();
NODE
MCP_RC=$?
[ "$MCP_RC" -eq 0 ] && ok "MCP e2e 链路返回码 0" || bad "MCP e2e 链路返回码 $MCP_RC"

# ---------------------------------------------------------------- 4. report.json
echo "-- 4. 产物落工作区（95-engine/smoke/report.json）"
REPORT="$WS/95-engine/smoke/report.json"
if [ -f "$REPORT" ]; then
  ok "report.json 存在"
  case "$REPORT" in
    "$WS"/95-engine/smoke/report.json) ok "report.json 落在临时工作区内" ;;
    *) bad "report.json 不在临时工作区内：$REPORT" ;;
  esac
  while IFS=$'\t' read -r okf name detail; do
    [ -n "$name" ] || continue
    if [ "$okf" = "1" ]; then
      ok "$name${detail:+（$detail）}"
    else
      bad "$name${detail:+（$detail）}"
    fi
  done < <(node -e '
    const r = require(process.argv[1]);
    (r.checks || []).forEach((c) => console.log((c.ok ? "1" : "0") + "\t" + c.name + "\t" + (c.detail || "")));
  ' "$REPORT" 2>/dev/null)
  if FIELDS="$(node -e '
    const r = require(process.argv[1]);
    const sid = r.session && r.session.session_id;
    const miss = [];
    if (!r.generated_at || typeof r.generated_at !== "string") miss.push("generated_at");
    if (r.tool_count !== 7) miss.push("tool_count=7");
    if (!r.title || !String(r.title).trim()) miss.push("title");
    if (!sid) miss.push("session.session_id");
    if (!r.session || r.session.deleted !== true) miss.push("session.deleted=true");
    if (!(r.nav && typeof r.nav.transfer_size === "number" && r.nav.transfer_size > 0)) miss.push("nav.transfer_size>0");
    if (!r.nav || r.nav.cache_hit !== false) miss.push("nav.cache_hit=false");
    if (miss.length) { console.error("缺/不符：" + miss.join(",")); process.exit(1); }
    console.log("tool_count=" + r.tool_count + " title=" + JSON.stringify(r.title) + " session_id=" + sid +
      " transfer_size=" + (r.nav && r.nav.transfer_size) + " cache_hit=" + (r.nav && r.nav.cache_hit) +
      " generated_at=" + r.generated_at);
  ' "$REPORT" 2>&1)"; then
    ok "report 字段齐（$FIELDS）"
  else
    bad "report 字段不齐（$FIELDS）"
  fi
else
  bad "report.json 缺失（$REPORT）"
fi

# ---------------------------------------------------------------- 5. 会话与边界
echo "-- 5. 会话收尾与边界"
SESS_JSON="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - "${GATEWAY_URL%/}/v1/sessions" 2>/dev/null || true)"
ALIVE="$(printf '%s' "$SESS_JSON" | node -e '
  let s = "";
  process.stdin.on("data", (d) => { s += d; });
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const suffix = ":" + process.argv[1];
      const alive = (j.sessions || []).filter((x) => String(x.account || "").endsWith(suffix) && x.alive);
      console.log(alive.length);
    } catch (e) { console.log(-1); }
  });
' "${E2E_ACCOUNT:-e2e-smoke}" 2>/dev/null || echo -1)"
case "$ALIVE" in
  0) ok "会话已删除（account *:${E2E_ACCOUNT:-e2e-smoke} 无 alive）" ;;
  -1) warn "读不到 /v1/sessions，跳过会话存活校验" ;;
  *) bad "会话仍存活（alive=$ALIVE，account *:${E2E_ACCOUNT:-e2e-smoke}）" ;;
esac
if [ -n "$REAL_MTIME" ]; then
  REAL_MTIME2="$(stat -f %m "$REAL_WS" 2>/dev/null || stat -c %Y "$REAL_WS" 2>/dev/null || true)"
  [ "$REAL_MTIME" = "$REAL_MTIME2" ] && ok "真工作区 mtime 未变（$REAL_MTIME）" || bad "真工作区 mtime 变了（$REAL_MTIME -> $REAL_MTIME2）"
fi
FARM_DIRTY2="$(git -C "$ROOT" status --porcelain farm | wc -l | tr -d ' ')"
[ "$FARM_DIRTY2" -eq 0 ] && ok "farm/ 改动 0 行（跑后）" || bad "farm/ 有 $FARM_DIRTY2 行改动"
if grep -rqF -- "$TOKEN" "$WS" 2>/dev/null; then
  bad "临时工作区出现 token 明文"
else
  ok "临时工作区无 token 明文（只经环境变量传子进程）"
fi

# ---------------------------------------------------------------- 汇总
echo
echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: READY"
  RC=0
else
  echo "RESULT: NOT_READY"
  RC=1
fi
echo "EXIT=$RC"
exit "$RC"
