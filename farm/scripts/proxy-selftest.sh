#!/usr/bin/env bash
# =============================================================================
# proxy-selftest.sh — 拿到代理后一条命令验通（桥 → curl → 探针 → 目标站）
#
# 用法：
#   # 真代理（凭据只走环境变量，绝不进 argv）
#   export UPSTREAM_PROXY='socks5h://user:pass@host:1080'
#   GATEWAY_TOKEN=... bash farm/scripts/proxy-selftest.sh
#   bash farm/scripts/proxy-selftest.sh --target-url 'https://www.ebay.com/sch/i.html?_nkw=usb+cable'
#
#   # 没有真代理：内置假上游自测脚本本身
#   GATEWAY_TOKEN=... bash farm/scripts/proxy-selftest.sh --self-test
#
#   # 不需要真代理：验证 camoufox worker 是否真把流量送进代理
#   bash farm/scripts/proxy-selftest.sh --worker-proxy
#
# 四步（真代理 / --self-test）：
#   1) 桥起来了，且凭据识别正确（上游带账号密码时必须是 auth=yes）
#   2) curl -x 桥 https://example.com/ → 200（CONNECT 隧道）
#   3) farm-probe 经桥取 example.com → ok（真实产品路径：MCP 建会话 → goto → 删会话）
#   4) 可选 --target-url（默认一个 eBay 搜索页）经桥探一次：
#      ok=PASS / blocked=INFO（如实报，不算 FAIL）/ empty=WARN / error=WARN（带 error.code）
# 收尾：停桥、清临时文件、凭据 grep 0。
#
# --worker-proxy：假上游（Basic 鉴权 + 访问日志）→ 桥 → camoufox_worker.py goto
#   `worker-fixture.test`（只由假上游应答；浏览器会把 127.0.0.1 按 loopback 绕过，不能用本地地址）。
#   断言 worker EXIT=0、readyState=complete、假上游日志里出现该请求；再不带 --proxy 跑同一命令，
#   该域名 DNS 失败、假上游日志必须为空（反向对照）。venv 不存在/import 失败记 WARN 跳过，
#   不判 FAIL（camoufox 是可选引擎）。
# 退出码：0 全通；1 桥或上游不通（步骤 1–3 有 FAIL，或凭据泄漏）；2 用法/前置不满足。
# 边界：--self-test 仍需本机能直连 example.com（假上游真转发）；不代表真代理出口可用。
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || exit 2   # farm/
ROOT="$(cd "$SRC/.." 2>/dev/null && pwd)" || exit 2
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL 找不到 node（先 export PATH=\"/opt/homebrew/bin:\$PATH\"）"; exit 2; }

SELFTEST=0
WORKER_PROXY=0
TARGET_URL=""
TIMEOUT_MS=45000
PORT=""
KEEP_TMP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELFTEST=1; shift ;;
    --worker-proxy) WORKER_PROXY=1; shift ;;
    --target-url) TARGET_URL="${2:-}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:-45000}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --keep-tmp) KEEP_TMP=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数 $1（用 --help 看用法）"; exit 2 ;;
  esac
done

if [ "$SELFTEST" = "1" ] && [ "$WORKER_PROXY" = "1" ]; then
  echo "用法错：--self-test 与 --worker-proxy 不能同时用（worker 模式自带假上游）" >&2; exit 2
fi

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
TOKEN="${GATEWAY_TOKEN:-${DSH_SECRET_GATEWAY_TOKEN:-}}"
PROBE="$ROOT/distribution/connectors/farm-probe.js"
BRIDGE="$SRC/proxy-bridge.js"

PASS=0; FAIL=0; INFO=0; WARN=0
ok(){   printf "  PASS %s\n" "$1"; PASS=$((PASS + 1)); }
no(){   printf "  FAIL %s\n" "$1"; FAIL=$((FAIL + 1)); }
info(){ printf "  INFO %s\n" "$1"; INFO=$((INFO + 1)); }
warn(){ printf "  WARN %s\n" "$1"; WARN=$((WARN + 1)); }

TMP="$(mktemp -d)" || exit 2
BPID=""
UPID=""
cleanup() {
  trap - EXIT
  if [ -n "$BPID" ]; then kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; fi
  if [ -n "$UPID" ]; then kill "$UPID" 2>/dev/null; wait "$UPID" 2>/dev/null; fi
  if [ "$KEEP_TMP" = "1" ]; then
    echo "  INFO 临时目录保留：$TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

wait_log() { # wait_log <file> <pattern> [tries]
  local f="$1" pat="$2" n="${3:-60}" i=0
  while [ "$i" -lt "$n" ]; do
    grep -q "$pat" "$f" 2>/dev/null && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

pick_port() {
  node -e 'const net=require("net");const s=net.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});s.on("error",()=>process.exit(1));'
}

probe_summary() { # probe_summary <json> → status<TAB>item_count<TAB>matched<TAB>error_code
  node -e 'const fs=require("fs");let d;try{d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){console.log(["parse_error",0,"",""].join("\t"));process.exit(0)}const m=(d.evidence&&d.evidence.matched)||[];console.log([d.status||"",d.item_count||0,m.join("|"),(d.error&&d.error.code)||""].join("\t"))' "$1"
}

echo "== 0. 前置 =="
[ -f "$BRIDGE" ] && ok "proxy-bridge.js 存在（${BRIDGE}）" || { no "缺 $BRIDGE"; }
[ -f "$PROBE" ]  && ok "farm-probe.js 存在（${PROBE}）"  || { no "缺 $PROBE"; }
if [ "$WORKER_PROXY" = "1" ]; then
  echo "  INFO worker-proxy 模式：不经网关，不需要 token（只验 worker → 桥 → 上游）"
else
  if [ -z "$TOKEN" ]; then
    echo "FAIL 需要 GATEWAY_TOKEN（只从环境变量读，不走 argv、不落文件）"
    echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN INFO=$INFO =="; echo "RESULT: FAILED"; exit 2
  fi
  ok "token 已从环境变量读取（长度 ${#TOKEN}，不打印值）"
  [ "${#TOKEN}" -lt 32 ] && warn "token 长度 ${#TOKEN} < 32（建议 openssl rand -hex 32；本次照跑）"
  hcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$GATEWAY_URL/v1/health" 2>/dev/null || true)"
  [ "$hcode" = "200" ] && ok "网关可达（$GATEWAY_URL/v1/health 200）" || { no "网关不可达（HTTP=${hcode}）；先 bash farm/scripts/start-gateway.sh --daemon"; }
  [ "$FAIL" -gt 0 ] && { echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN INFO=$INFO =="; echo "RESULT: FAILED"; exit 2; }
fi

UP_USER=""
UP_PASS=""
EXPECT_AUTH="no"
UPSTREAM_URL=""

if [ "$SELFTEST" = "1" ] || [ "$WORKER_PROXY" = "1" ]; then
  echo "== 0b. 内置假上游（自测模式，不需要真代理）=="
  UPORT="$(pick_port)" || { no "选不到空闲上游端口"; exit 2; }
  UP_PASS="$(openssl rand -hex 12 2>/dev/null || printf 'p%s' "$$")"
  UP_USER="probe"
  EXPECTED_AUTH="Basic $(printf '%s:%s' "$UP_USER" "$UP_PASS" | base64 | tr -d '\n')"
  UPSTREAM_URL="http://${UP_USER}:${UP_PASS}@127.0.0.1:${UPORT}"
  EXPECT_AUTH="yes"
  RECEIPT="$TMP/receipt.log"; : > "$RECEIPT"
  cat > "$TMP/fake-upstream.js" <<'FAKE_JS'
'use strict';
const http = require('http');
const net = require('net');
const fs = require('fs');
const { URL } = require('url');

const PORT = Number(process.env.FAKE_PORT || 0);
const EXPECTED = process.env.EXPECTED_AUTH || '';
const RECEIPT = process.env.RECEIPT;

function rec(line) { try { fs.appendFileSync(RECEIPT, line + '\n'); } catch (e) {} }
function authed(req) { return !!EXPECTED && req.headers['proxy-authorization'] === EXPECTED; }

const BLOCKED_PAGE = '<!doctype html><html><head><title>Robot or human?</title></head>'
  + '<body>Robot or human? Activate and hold the button to confirm that you\u2019re human.</body></html>';

const server = http.createServer((req, res) => {
  if (!authed(req)) {
    rec('HDR_BAD GET ' + String(req.url).slice(0, 80));
    res.writeHead(407, { 'Proxy-Authenticate': 'Basic realm="fake-upstream"' });
    res.end('407');
    return;
  }
  let target = null;
  try { target = new URL(String(req.url)); } catch (e) { target = null; }
  if (!target || target.protocol !== 'http:') { res.writeHead(400); res.end('bad absolute uri'); return; }
  rec('HDR_OK GET ' + target.host);
  /* worker-proxy 专用：这个域名只由假上游应答，证明 worker 真的把流量送进了代理 */
  if (target.hostname === 'worker-fixture.test') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end('<!doctype html><html><head><title>Worker Fixture</title></head><body><h1>worker proxy fixture</h1></body></html>');
    return;
  }
  /* 自测专用：拦截页样本，用来验证「blocked 记 INFO 不算 FAIL」这一支 */
  if (target.hostname === 'robot-wall.test') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(BLOCKED_PAGE);
    return;
  }
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
  }, (r) => { res.writeHead(r.statusCode || 502, r.headers); r.pipe(res); });
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
    client.pipe(target); target.pipe(client);
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
    node "$TMP/fake-upstream.js" >"$TMP/upstream.log" 2>&1 &
  UPID=$!
  if wait_log "$TMP/upstream.log" '^READY'; then
    ok "假上游已起（127.0.0.1:${UPORT}，要求 Basic 鉴权）"
  else
    no "假上游未起"; cat "$TMP/upstream.log" 2>/dev/null
    echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN INFO=$INFO =="; echo "RESULT: FAILED"; exit 1
  fi
  TEST_TARGET="${TARGET_URL:-http://robot-wall.test/}"
else
  echo "== 0b. 上游代理 =="
  if [ -z "${UPSTREAM_PROXY:-}" ]; then
    echo "FAIL 需要 UPSTREAM_PROXY=http://… 或 socks5://… / socks5h://…（只从环境变量读，不走 argv）"
    echo "     没有真代理想先验脚本：bash $0 --self-test"
    echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN INFO=$INFO =="; echo "RESULT: FAILED"; exit 2
  fi
  UPSTREAM_URL="$UPSTREAM_PROXY"
  case "$UPSTREAM_URL" in
    http://*|socks5://*|socks5h://*) ok "UPSTREAM_PROXY 协议受支持（只报 scheme，不打印值）" ;;
    *) no "UPSTREAM_PROXY 协议不支持（只支持 http:// / socks5:// / socks5h://）"; exit 2 ;;
  esac
  cred="$(printf '%s' "$UPSTREAM_URL" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const u=new URL(s.trim());console.log(decodeURIComponent(u.username||""));console.log(decodeURIComponent(u.password||""));}catch(e){console.log("");console.log("");}})')"
  UP_USER="$(printf '%s\n' "$cred" | sed -n 1p)"
  UP_PASS="$(printf '%s\n' "$cred" | sed -n 2p)"
  if [ -n "$UP_USER$UP_PASS" ]; then EXPECT_AUTH="yes"; else EXPECT_AUTH="no"; fi
  TEST_TARGET="${TARGET_URL:-https://www.ebay.com/sch/i.html?_nkw=wireless+earbuds}"
fi

[ -n "$PORT" ] || PORT="$(pick_port)" || { no "选不到空闲桥端口"; exit 2; }

echo "== 1. 起桥（凭据只走环境变量）=="
env -i PATH="$PATH" UPSTREAM_PROXY="$UPSTREAM_URL" node "$BRIDGE" --port "$PORT" \
  >"$TMP/bridge.log" 2>&1 &
BPID=$!
if wait_log "$TMP/bridge.log" 'listen 127.0.0.1'; then
  ok "bridge 已起（127.0.0.1:${PORT}）"
  sed -n '1p' "$TMP/bridge.log" | sed 's/^/  INFO /' | head -2
else
  no "bridge 未起（日志见下）"; cat "$TMP/bridge.log" 2>/dev/null
  echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN INFO=$INFO =="; echo "RESULT: FAILED"; exit 1
fi
if [ "$EXPECT_AUTH" = "yes" ]; then
  grep -q 'auth=yes' "$TMP/bridge.log" && ok "桥识别到上游凭据（auth=yes）" || no "上游带账号密码但桥没识别（日志里没有 auth=yes）"
else
  grep -q 'auth=no' "$TMP/bridge.log" && ok "上游无凭据，桥按 auth=no 起（符合）" || no "上游无凭据但桥日志不是 auth=no"
fi

if [ "$WORKER_PROXY" = "1" ]; then
  echo "== 2. camoufox worker 经桥取页（假上游记录访问日志）=="
  PY="$HOME/.dsh/venvs/camoufox/bin/python"
  WORKER="$SRC/camoufox_worker.py"
  # worker-fixture.test 只由假上游应答：带 --proxy 才能拿到页面，不带就会 DNS 失败。
  # 这样「页面加载成功 + 假上游日志命中」只能是真的走了代理（127.0.0.1 会被浏览器按 loopback 绕过）。
  FIXTURE_URL="http://worker-fixture.test/page"
  worker_state() { # worker_state <json> [expected_url] → ok|bad
    node -e 'const fs=require("fs");let d;try{d=JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).pop())}catch(e){process.stdout.write("bad");process.exit(0)}const u=process.argv[2]||"";process.stdout.write(d.ok===true&&d.result&&d.result.readyState==="complete"&&(!u||d.result.url===u)?"ok":"bad")' "$1" "${2:-}" 2>/dev/null || printf 'bad'
  }
  if [ ! -x "$PY" ]; then
    warn "worker-proxy 跳过：camoufox venv 不存在（${PY}；camoufox 是可选引擎，不判 FAIL）"
  elif ! "$PY" -c 'import camoufox' >/dev/null 2>&1; then
    warn "worker-proxy 跳过：$PY 里 import camoufox 失败（可选引擎，不判 FAIL）"
  else
    : > "$RECEIPT"   # 只统计本轮
    "$PY" "$WORKER" --account acc-wp-proxy --profile "$TMP/wprofile-proxy" --headless \
      --proxy "http://127.0.0.1:$PORT" \
      --task "{\"type\":\"goto\",\"params\":{\"url\":\"$FIXTURE_URL\",\"timeout_ms\":20000}}" \
      >"$TMP/worker-proxy.json" 2>"$TMP/worker-proxy.err"
    RCP=$?
    WP1="$(worker_state "$TMP/worker-proxy.json" "$FIXTURE_URL")"
    if [ "$RCP" = "0" ] && [ "$WP1" = "ok" ]; then
      ok "worker（带 --proxy）EXIT=0、readyState=complete、页面来自假上游"
    else
      no "worker（带 --proxy）失败：EXIT=$RCP $(head -c 200 "$TMP/worker-proxy.err" 2>/dev/null)"
    fi
    if grep -q "HDR_OK GET worker-fixture.test" "$RECEIPT" 2>/dev/null; then
      ok "假上游日志出现 worker-fixture.test 请求（流量真走了代理）"
    else
      no "假上游日志没有 worker-fixture.test 请求（worker 可能没走代理）；日志原文：$(head -c 300 "$RECEIPT" 2>/dev/null)"
    fi
    : > "$RECEIPT"
    "$PY" "$WORKER" --account acc-wp-direct --profile "$TMP/wprofile-direct" --headless \
      --task "{\"type\":\"goto\",\"params\":{\"url\":\"$FIXTURE_URL\",\"timeout_ms\":20000}}" \
      >"$TMP/worker-direct.json" 2>"$TMP/worker-direct.err"
    RCD=$?
    if [ -s "$RECEIPT" ]; then
      no "对照假上游日志非空（反向断言失效）：$(head -c 300 "$RECEIPT")"
    else
      ok "对照（不带 --proxy）假上游日志为空（没走代理）"
    fi
    if [ "$RCD" = "0" ]; then
      info "对照竟然加载成功（EXIT=0）——$FIXTURE_URL 本应只有代理能应答，反向对照说服力下降"
    else
      info "对照按预期失败（EXIT=${RCD}，该域名只有代理能应答）"
    fi
  fi
else
echo "== 2. curl 走桥 =="
c1="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 -x "http://127.0.0.1:$PORT" https://example.com/ 2>"$TMP/c1.err" || true)"
if [ "$c1" = "200" ]; then
  ok "curl -x 桥 https://example.com/ → HTTP 200"
else
  no "curl https 失败：HTTP=$c1 $(head -c 200 "$TMP/c1.err" 2>/dev/null)"
fi

echo "== 3. 探针走桥（example.com 必须 ok）=="
GATEWAY_TOKEN="$TOKEN" env -u UPSTREAM_PROXY HOME="${HOME:-/tmp}" PATH="$PATH" \
  node "$PROBE" --url 'https://example.com/' --proxy "http://127.0.0.1:$PORT" \
  --cache-bust --timeout-ms "$TIMEOUT_MS" >"$TMP/probe1.json" 2>"$TMP/probe1.err"
rc1=$?
IFS=$'\t' read -r ps1 pi1 pm1 pe1 <<<"$(probe_summary "$TMP/probe1.json")"
if [ "$ps1" = "ok" ] && [ "${pi1:-0}" -ge 1 ]; then
  ok "farm-probe 经桥 example.com → ok（item_count=${pi1}，EXIT=${rc1}）"
else
  no "farm-probe 经桥 example.com 未 ok：status=${ps1:-?} item_count=${pi1:-0} code=${pe1:-none} EXIT=$rc1 $(head -c 160 "$TMP/probe1.err" 2>/dev/null)"
fi

echo "== 4. 目标站经桥探一次（blocked 记 INFO，不算 FAIL）=="
echo "  INFO target=$TEST_TARGET"
GATEWAY_TOKEN="$TOKEN" env -u UPSTREAM_PROXY HOME="${HOME:-/tmp}" PATH="$PATH" \
  node "$PROBE" --url "$TEST_TARGET" --proxy "http://127.0.0.1:$PORT" \
  --cache-bust --timeout-ms "$TIMEOUT_MS" >"$TMP/probe2.json" 2>"$TMP/probe2.err"
rc2=$?
IFS=$'\t' read -r ps2 pi2 pm2 pe2 <<<"$(probe_summary "$TMP/probe2.json")"
case "$ps2" in
  ok)      ok "目标站经桥取到数据（item_count=${pi2}，EXIT=${rc2}）" ;;
  blocked) info "目标站被拦（matched=${pm2:-none}，EXIT=${rc2}）——如实报，不算 FAIL" ;;
  empty)   warn "目标站可达但没取到条目（item_count=0，EXIT=${rc2}）" ;;
  error)   warn "目标站经桥探失败（code=${pe2:-none}，EXIT=${rc2}）——检查目标站/出口，不算桥故障" ;;
  *)       warn "目标站结果无法解析（status=${ps2:-?}，EXIT=${rc2}）" ;;
esac
fi

echo "== 5. 收尾 =="
kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null; BPID=""
sleep 0.2
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  no "桥已杀但端口 $PORT 仍在监听"
else
  ok "桥已停，端口 $PORT 已释放"
fi

leak=0
for f in "$TMP/bridge.log" "$TMP/probe1.json" "$TMP/probe1.err" "$TMP/probe2.json" "$TMP/probe2.err" "$TMP/c1.err" "$TMP/upstream.log" "$TMP/receipt.log" "$TMP/worker-proxy.json" "$TMP/worker-proxy.err" "$TMP/worker-direct.json" "$TMP/worker-direct.err"; do
  [ -f "$f" ] || continue
  if [ -n "$UP_PASS" ] && grep -Fq "$UP_PASS" "$f"; then leak=$((leak + 1)); fi
  if [ -n "$UP_USER" ] && grep -Fq "$UP_USER:" "$f"; then leak=$((leak + 1)); fi
done
if [ "$leak" -eq 0 ]; then ok "凭据 grep 0（桥日志/探针输出/curl/假上游）"; else no "凭据出现在输出里（命中 $leak 处）"; fi
if printf '%s\n' "$TOKEN" | grep -Fq -f - "$TMP/bridge.log" 2>/dev/null; then no "网关 token 出现在桥日志"; else ok "网关 token 未出现在任何输出"; fi

echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN INFO=$INFO =="
if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAILED"; exit 1
fi
if [ "$SELFTEST" = "1" ] && [ -n "${ps2:-}" ] && ! echo "$ps2" | grep -q 'blocked'; then
  echo "  WARN 自测期望第 4 步是 blocked（假上游拦截页），实际 ${ps2:-?}"
fi
echo "RESULT: READY"; exit 0
