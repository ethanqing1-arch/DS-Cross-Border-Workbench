#!/usr/bin/env bash
# =============================================================================
# test-proxy-bridge.sh — proxy-bridge.js 的自证（假上游 + 真浏览器两条链路）
#
# 验证什么：
#   1) 假上游（127.0.0.1:<upstream-port>，自带 Basic 鉴权校验、记录是否收到
#      Proxy-Authorization、真转发到 example.com）收到 bridge 注入的鉴权头
#   2) curl -x 桥 https://example.com/   → 200（CONNECT 隧道）
#   3) curl -x 桥 http://example.com/    → 2xx/3xx（绝对 URI 普通请求）
#   4) 真实产品路径：MCP farm_session_create（proxy=桥，无凭据）
#      → farm_task goto https://example.com/?pb=<cache-bust> → farm_session_delete
#      浏览器那一路也让假上游收到 Proxy-Authorization
#
# 边界：
#   - 凭据只从环境变量进 bridge（env -i 起子进程），输出里 grep 不到
#   - 网关 token 只从环境变量读，不进 argv；curl 用 -K - 走 stdin
#   - 复用台账账号 e2e-smoke（不新增行）；会话用完即删
#
# 用法：
#   GATEWAY_TOKEN=... bash scripts/test-proxy-bridge.sh [--port 18080] [--upstream-port 18581]
#   环境变量：GATEWAY_URL（默认 http://127.0.0.1:19671）
# 退出码：0 全过；1 有 FAIL；2 前置条件不满足（网关/token/node）
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"; cd "$SRC" || exit 2
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL 找不到 node（先 export PATH=\"/opt/homebrew/bin:\$PATH\"）"; exit 2; }

BPORT=18080
UPORT=18581
while [ $# -gt 0 ]; do
  case "$1" in
    --port) BPORT="$2"; shift 2 ;;
    --upstream-port) UPORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
TOKEN="${GATEWAY_TOKEN:-${DSH_SECRET_GATEWAY_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "FAIL 需要 GATEWAY_TOKEN（只从环境变量读，不走 argv、不落文件）"; exit 2; }

PASS=0
FAIL=0
ok(){ printf "  PASS %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL %s\n" "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)" || exit 2
UPID=""
BPID=""
cleanup() {
  trap - EXIT
  if [ -n "$BPID" ]; then kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; fi
  if [ -n "$UPID" ]; then kill "$UPID" 2>/dev/null; wait "$UPID" 2>/dev/null; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_log() { # wait_log <file> <pattern> [tries]
  local f="$1" pat="$2" n="${3:-60}"
  local i=0
  while [ "$i" -lt "$n" ]; do
    grep -q "$pat" "$f" 2>/dev/null && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

echo "== 0. 前置 =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$GATEWAY_URL/v1/health" 2>/dev/null || true)"
if [ "$code" != "200" ]; then
  echo "FAIL 网关不可达 $GATEWAY_URL/v1/health（HTTP=$code）；先 bash scripts/start-gateway.sh --daemon"
  exit 2
fi
ok "网关可达（$GATEWAY_URL/v1/health 200）"
ok "token 已从环境变量读取（长度 ${#TOKEN}，不打印值）"
[ "${#TOKEN}" -lt 32 ] && echo "  WARN token 长度 ${#TOKEN} < 32（建议 openssl rand -hex 32；本次照跑）"

# 凭据只存在这个 shell 的变量里，通过 env 传给 bridge；不落文件、不打印
UP_PASS="$(openssl rand -hex 12)"
EXPECTED_AUTH="Basic $(printf 'probe:%s' "$UP_PASS" | base64 | tr -d '\n')"
UP_URL="http://probe:${UP_PASS}@127.0.0.1:${UPORT}"
RECEIPT="$TMP/receipt.log"
: > "$RECEIPT"

echo "== 1. 假上游（要求 Basic 鉴权，记录头，真转发）=="
cat > "$TMP/fake-upstream.js" <<'FAKE_JS'
'use strict';
const http = require('http');
const net = require('net');
const fs = require('fs');
const { URL } = require('url');

const PORT = Number(process.env.FAKE_PORT || 18581);
const EXPECTED = process.env.EXPECTED_AUTH || '';
const RECEIPT = process.env.RECEIPT;

function rec(line) {
  try { fs.appendFileSync(RECEIPT, line + '\n'); } catch (e) { /* ignore */ }
}
function authed(req) {
  return !!EXPECTED && req.headers['proxy-authorization'] === EXPECTED;
}

const server = http.createServer((req, res) => {
  if (!authed(req)) {
    rec('HDR_BAD GET ' + String(req.url).slice(0, 80));
    res.writeHead(407, { 'Proxy-Authenticate': 'Basic realm="fake-upstream"' });
    res.end('407');
    return;
  }
  let target = null;
  try { target = new URL(String(req.url)); } catch (e) { target = null; }
  if (!target || target.protocol !== 'http:') {
    res.writeHead(400);
    res.end('bad absolute uri');
    return;
  }
  rec('HDR_OK GET ' + target.host);
  const headers = Object.assign({}, req.headers);
  headers.host = target.host;
  delete headers['proxy-authorization'];
  delete headers['proxy-connection'];
  const up = http.request({
    hostname: target.hostname,
    port: Number(target.port || 80),
    method: req.method,
    path: target.pathname + target.search,
    headers,
  }, (r) => {
    res.writeHead(r.statusCode || 502, r.headers);
    r.pipe(res);
  });
  up.on('error', () => { try { res.writeHead(502); res.end('502'); } catch (e) {} });
  req.pipe(up);
});

server.on('connect', (req, client, head) => {
  const dest = String(req.url || '');
  if (!authed(req)) {
    rec('HDR_BAD CONNECT ' + dest);
    client.end('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="fake-upstream"\r\n\r\n');
    return;
  }
  rec('HDR_OK CONNECT ' + dest);
  const i = dest.lastIndexOf(':');
  const host = i > 0 ? dest.slice(0, i) : dest;
  const port = i > 0 ? Number(dest.slice(i + 1)) : 443;
  const target = net.connect({ host, port }, () => {
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) target.write(head);
    client.pipe(target);
    target.pipe(client);
  });
  target.on('error', () => { try { client.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (e) {} });
  client.on('error', () => target.destroy());
  client.on('close', () => target.destroy());
  target.on('close', () => client.destroy());
});

server.on('error', (e) => { console.error('fake-upstream: ' + e.message); process.exit(1); });
server.listen(PORT, '127.0.0.1', () => console.log('READY ' + PORT));
FAKE_JS

env -i PATH="$PATH" FAKE_PORT="$UPORT" EXPECTED_AUTH="$EXPECTED_AUTH" RECEIPT="$RECEIPT" \
  node "$TMP/fake-upstream.js" >"$TMP/fake.log" 2>&1 &
UPID=$!
if wait_log "$TMP/fake.log" '^READY'; then
  ok "假上游已起（127.0.0.1:$UPORT，缺失/错误 Proxy-Authorization 一律 407）"
else
  no "假上游未起"; cat "$TMP/fake.log" 2>/dev/null; echo "== 汇总: PASS=$PASS FAIL=$FAIL =="; echo "RESULT: FAILED"; exit 1
fi

echo "== 2. 起 bridge（上游凭据只走环境变量）=="
env -i PATH="$PATH" UPSTREAM_PROXY="$UP_URL" node "$SRC/proxy-bridge.js" --port "$BPORT" \
  >"$TMP/bridge.log" 2>&1 &
BPID=$!
if wait_log "$TMP/bridge.log" 'listen 127.0.0.1'; then
  ok "bridge 已起（127.0.0.1:$BPORT）"
else
  no "bridge 未起"; cat "$TMP/bridge.log" 2>/dev/null; echo "== 汇总: PASS=$PASS FAIL=$FAIL =="; echo "RESULT: FAILED"; exit 1
fi
grep -q 'auth=yes' "$TMP/bridge.log" && ok "bridge 识别到上游带凭据（auth=yes）" || no "bridge 未识别上游凭据（日志见下）"
if grep -q 'probe:' "$TMP/bridge.log"; then no "bridge 日志出现凭据片段"; else ok "bridge 日志不含凭据"; fi

echo "== 3. curl 两条路径 =="
c1="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 -x "http://127.0.0.1:$BPORT" https://example.com/ 2>"$TMP/c1.err" || true)"
[ "$c1" = "200" ] && ok "curl -x 桥 https://example.com/ → HTTP 200" || no "curl https 失败：HTTP=$c1 $(head -c 160 "$TMP/c1.err" 2>/dev/null)"
if grep -q 'HDR_OK CONNECT example.com:443' "$RECEIPT"; then
  ok "假上游收到 CONNECT 的 Proxy-Authorization（example.com:443）"
else
  no "假上游没收到 CONNECT 的 Proxy-Authorization"
fi

c2="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 -x "http://127.0.0.1:$BPORT" http://example.com/ 2>"$TMP/c2.err" || true)"
case "$c2" in
  2??|3??) ok "curl -x 桥 http://example.com/ → HTTP $c2（绝对 URI）" ;;
  *) no "curl http 失败：HTTP=$c2 $(head -c 160 "$TMP/c2.err" 2>/dev/null)" ;;
esac
if grep -q 'HDR_OK GET example.com' "$RECEIPT"; then
  ok "假上游收到 GET 的 Proxy-Authorization（绝对 URI）"
else
  no "假上游没收到 GET 的 Proxy-Authorization"
fi
if grep -q 'HDR_BAD' "$RECEIPT"; then
  no "假上游收到过鉴权失败请求（$(grep -c 'HDR_BAD' "$RECEIPT") 次）"
else
  ok "假上游未收到任何鉴权失败请求"
fi

echo "== 4. 真实产品路径（MCP 建会话带 proxy=桥 → goto → 删会话）=="
cat > "$TMP/mcp-client.js" <<'MCP_JS'
'use strict';
const { spawn } = require('child_process');
const readline = require('readline');
const fs = require('fs');

const MCP = process.env.MCP_PATH;
const ACCOUNT = process.env.TEST_ACCOUNT || 'e2e-smoke';
const PROXY = process.env.TEST_PROXY;
const SID_FILE = process.env.SID_FILE;
const TARGET = process.env.TEST_TARGET || 'https://example.com/';

const out = { ok: false };

function finish(code) {
  try { child.stdin.end(); } catch (e) { /* already closed */ }
  process.stdout.write(JSON.stringify(out) + '\n', () => process.exit(code));
}

const child = spawn(process.execPath, [MCP], { stdio: ['pipe', 'pipe', 'inherit'], env: process.env });
const pending = new Map();
let nextId = 1;
const rl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
rl.on('line', (line) => {
  let msg = null;
  try { msg = JSON.parse(line); } catch (e) { return; }
  if (!msg || msg.id === undefined) return;
  const p = pending.get(msg.id);
  if (!p) return;
  pending.delete(msg.id);
  clearTimeout(p.timer);
  if (msg.error) p.reject(new Error('JSON-RPC error: ' + JSON.stringify(msg.error)));
  else p.resolve(msg.result);
});
child.on('exit', (code) => {
  for (const [, p] of pending) {
    clearTimeout(p.timer);
    p.reject(new Error('MCP 进程退出 code=' + code));
  }
  pending.clear();
});

function request(method, params, timeoutMs) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('超时 ' + method)); }, timeoutMs || 150000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}
function notify(method, params) {
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
}
async function call(name, args, timeoutMs) {
  const r = await request('tools/call', { name, arguments: args || {} }, timeoutMs);
  const text = (r && r.content && r.content[0] && r.content[0].text) || '';
  let data = null;
  try { data = JSON.parse(text); } catch (e) { data = null; }
  return { isError: !!(r && r.isError), text, data };
}

(async () => {
  let sessionId = null;
  let deleted = false;
  try {
    const init = await request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'proxy-bridge-test', version: '0.1.0' },
    }, 20000);
    out.server = init && init.serverInfo ? init.serverInfo.name : null;
    if (out.server !== 'farm-gateway') throw new Error('initialize 失败：' + out.server);
    notify('notifications/initialized', {});

    const list = await request('tools/list', {}, 20000);
    out.tool_count = ((list && list.tools) || []).length;
    if (out.tool_count !== 7) throw new Error('tools/list 数量=' + out.tool_count);

    // 复用 e2e-smoke 前先清残留（没有会话时失败可忽略）
    try {
      const pre = await call('farm_session_delete', { session_id: 'default:' + ACCOUNT }, 20000);
      out.pre_delete = !pre.isError;
    } catch (e) { out.pre_delete = false; }

    const create = await call('farm_session_create', {
      account: ACCOUNT, engine: 'chromium', platform: 'e2e',
      proxy: PROXY, headless: true, require_check: false,
    }, 90000);
    const c = create.data || {};
    sessionId = c.session_id || null;
    out.session_id = sessionId;
    out.create_ok = !create.isError && !!sessionId && c.ok !== false;
    if (!out.create_ok) throw new Error('create 失败：' + String(create.text).slice(0, 300));
    if (SID_FILE) fs.writeFileSync(SID_FILE, sessionId + '\n');

    const goto = await call('farm_task', {
      session_id: sessionId, type: 'goto',
      params: { url: TARGET }, wait_ms: 90000,
    }, 120000);
    const g = goto.data || {};
    out.goto_status = g.status || null;
    out.goto_ok = !!(g.result && g.result.ok === true);
    out.goto_url = (g.result && g.result.url) || null;
    out.ready_state = (g.result && g.result.readyState) || null;
    if (g.status !== 'succeeded' || !out.goto_ok) throw new Error('goto 失败：' + String(goto.text).slice(0, 300));

    const del = await call('farm_session_delete', { session_id: sessionId }, 60000);
    const d = del.data || {};
    deleted = !del.isError && d.ok === true;
    out.deleted = deleted;
    out.status = d.status || null;
    out.data_retained = d.data_retained === undefined ? null : d.data_retained;
    if (!deleted) throw new Error('delete 失败：' + String(del.text).slice(0, 300));
    if (SID_FILE) fs.writeFileSync(SID_FILE, '');
    out.ok = true;
    try { child.stdin.end(); } catch (e) {}
    finish(0);
  } catch (err) {
    out.error = String((err && err.message) || err);
    if (sessionId && !deleted) {
      try {
        const del = await call('farm_session_delete', { session_id: sessionId }, 15000);
        out.rollback_deleted = !del.isError && !!(del.data && del.data.ok);
        if (out.rollback_deleted && SID_FILE) fs.writeFileSync(SID_FILE, '');
      } catch (e2) { out.rollback_deleted = false; }
    }
    try { child.stdin.end(); } catch (e3) {}
    finish(1);
  }
})();
MCP_JS

# example.com 带 max-age=86000，profile 里可能有缓存；加 cache-bust 参数保证浏览器必须走网络
TARGET_URL="https://example.com/?proxy-bridge=$(date +%s)-$RANDOM"
before_browser="$(grep -c 'HDR_OK CONNECT example.com:443' "$RECEIPT" 2>/dev/null || true)"
[ -n "$before_browser" ] || before_browser=0

env GATEWAY_URL="$GATEWAY_URL" GATEWAY_TOKEN="$TOKEN" \
    MCP_PATH="$SRC/mcp/farm-mcp.js" TEST_ACCOUNT="e2e-smoke" \
    TEST_PROXY="http://127.0.0.1:$BPORT" TEST_TARGET="$TARGET_URL" SID_FILE="$TMP/sid" \
    node "$TMP/mcp-client.js" >"$TMP/mcp.json" 2>"$TMP/mcp.err"
MRC=$?
cat "$TMP/mcp.json" 2>/dev/null | sed 's/^/  [mcp] /'
if [ "$MRC" -eq 0 ]; then
  ok "产品路径：farm_session_create(proxy=桥) → farm_task goto → farm_session_delete"
else
  no "产品路径失败（exit=$MRC）"; sed 's/^/  [mcp:err] /' "$TMP/mcp.err" 2>/dev/null | head -40
fi

after_browser="$(grep -c 'HDR_OK CONNECT example.com:443' "$RECEIPT" 2>/dev/null || true)"
[ -n "$after_browser" ] || after_browser=0
if [ "$after_browser" -gt "$before_browser" ]; then
  ok "浏览器那一路也让假上游收到 Proxy-Authorization（CONNECT 次数 $before_browser → $after_browser）"
else
  no "浏览器那一路没有经过 bridge（CONNECT 次数 $before_browser → $after_browser）"
  echo "  --- bridge.log（末尾 20 行）---"
  tail -20 "$TMP/bridge.log" 2>/dev/null | sed 's/^/  /'
  echo "  --- receipt（全部）---"
  sed 's/^/  /' "$RECEIPT" 2>/dev/null
fi

if [ -s "$TMP/sid" ]; then
  sid="$(cat "$TMP/sid")"
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
    | curl -sS -K - -X DELETE "$GATEWAY_URL/v1/sessions/$sid" >/dev/null 2>&1 || true
fi

echo "== 5. 泄漏扫描 =="
leak=0
for f in "$TMP/bridge.log" "$TMP/fake.log" "$TMP/mcp.json" "$TMP/mcp.err"; do
  if [ -f "$f" ] && grep -qF "$UP_PASS" "$f" 2>/dev/null; then leak=$((leak + 1)); fi
done
[ "$leak" -eq 0 ] && ok "bridge/fake/mcp 输出里 grep 不到上游凭据" || no "输出里出现上游凭据（$leak 个文件）"
grep -qF "$TOKEN" "$TMP/bridge.log" 2>/dev/null && no "bridge 日志里出现网关 token" || ok "bridge 日志里没有网关 token"
if grep -qF "$UP_PASS" "$TMP/bridge.log" 2>/dev/null || grep -qF "$UP_PASS" "$TMP/fake.log" 2>/dev/null; then
  no "bridge/fake 日志出现上游密码"
else
  ok "bridge/fake 日志不含上游密码"
fi

echo
echo "== 汇总: PASS=$PASS FAIL=$FAIL =="
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: READY"
  exit 0
else
  echo "RESULT: NOT_READY"
  exit 1
fi
