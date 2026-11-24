#!/usr/bin/env bash
# =============================================================================
# acceptance.sh — DS-Bot 接入前的自检（一条命令给出 PASS/FAIL 清单）
# 用法：bash scripts/acceptance.sh [--with-browser]
# 退出码：0 全通过；1 有 FAIL（WARN 不计）
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"; cd "$SRC" || exit 2
WITH_BROWSER=0; [ "${1:-}" = "--with-browser" ] && WITH_BROWSER=1
ACCEPT_PORT="${ACCEPT_PORT:-19671}"                    # 自检网关端口，可用环境变量覆盖（避免与真部署撞）
ACCEPT_CONTROL_PORT="${ACCEPT_CONTROL_PORT:-19571}"    # 自检 control 端口
PASS=0; FAIL=0; WARN=0
ok(){ printf "  \033[32mPASS\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
wn(){ printf "  \033[33mWARN\033[0m %s\n" "$1"; WARN=$((WARN+1)); }

echo "== 1. 文件完整性 =="
for f in farm.js control.js ledger.js driver.js contract.js proxy-bridge.js gateway/server.js mcp/farm-mcp.js docker/Dockerfile docker/entry.sh \
         scripts/mock-ip-echo.js scripts/verify-dual-env.sh scripts/test-proxy-bridge.sh scripts/proxy-selftest.sh scripts/ledger-clean.sh scripts/first-fetch.sh camoufox_worker.py \
         docs/dsbot-workbench-architecture.md docs/dsbot-workbench-review.md; do
  [ -f "$f" ] && ok "$f" || no "缺文件 $f"
done

echo "== 2. 语法 =="
for f in farm.js control.js ledger.js driver.js contract.js proxy-bridge.js gateway/server.js mcp/farm-mcp.js scripts/mock-ip-echo.js; do
  node --check "$f" 2>/dev/null && ok "node --check $f" || no "语法错 $f"
done
python3 -c "import ast;ast.parse(open('camoufox_worker.py').read())" 2>/dev/null && ok "camoufox_worker.py" || no "camoufox_worker.py 语法错"
bash -n scripts/verify-dual-env.sh 2>/dev/null && ok "verify-dual-env.sh" || no "verify-dual-env.sh 语法错"
bash -n scripts/test-proxy-bridge.sh 2>/dev/null && ok "test-proxy-bridge.sh" || no "test-proxy-bridge.sh 语法错"
bash -n scripts/proxy-selftest.sh 2>/dev/null && ok "proxy-selftest.sh" || no "proxy-selftest.sh 语法错"
bash -n scripts/ledger-clean.sh 2>/dev/null && ok "ledger-clean.sh" || no "ledger-clean.sh 语法错"
bash -n scripts/first-fetch.sh 2>/dev/null && ok "first-fetch.sh" || no "first-fetch.sh 语法错"
# bridge 配置校验：无上游 / 坏格式 / socks5 缺端口 / 不支持的协议都必须拒绝启动（exit 2；不联网不监听）
# 注意：这里不断言 socks5 不可用——socks5/socks5h 是受支持的上游，只校验坏配置会退出。
node -e '
const { spawnSync } = require("child_process");
const env = Object.assign({}, process.env);
delete env.UPSTREAM_PROXY;
const run = (args) => spawnSync(process.execPath, ["proxy-bridge.js"].concat(args), { env, timeout: 3000 });
const cases = [
  run([]),                                        // 无上游
  run(["--upstream", "not-a-url"]),                // 坏格式
  run(["--upstream", "socks5://127.0.0.1"]),       // socks5 缺端口
  run(["--upstream", "socks5://"]),                // socks5 缺 host/端口
  run(["--upstream", "socks4://127.0.0.1:1080"]),  // 不支持的协议
];
process.exit(cases.every((r) => r.status === 2) ? 0 : 1);
' 2>/dev/null && ok "bridge 无上游/坏格式/socks5 缺端口拒绝启动（exit 2）" || no "bridge 配置校验失效"

echo "== 3. 能力声明 =="
grep -q "chromium:" contract.js && grep -q "linux150:" contract.js \
  && grep -q "chrome:" contract.js && grep -q "camoufox:" contract.js \
  && ok "ENGINE_CAPS 四引擎齐全（contract.js）" || no "contract.js 缺引擎"
grep -q "require('../contract')" gateway/server.js && ok "网关从 contract.js 取能力" || no "网关未接契约"
grep -q "TASK_REGISTRY" gateway/server.js && ok "TASK_REGISTRY 存在" || no "TASK_REGISTRY 缺失"
grep -q "TASK_TTL" gateway/server.js && ok "任务幂等 TTL" || no "任务 TTL 缺失"
grep -q "runWorkerTask" gateway/server.js && ok "camoufox worker 任务通道" || no "缺 worker 任务通道"
grep -q "profileDirFor" farm.js && ok "profile 按平台分区" || no "缺 profile 分区"
node -e "const c=require('./contract.js');const v=c.check(c.VERSION);process.exit(v.ok?0:1)" 2>/dev/null \
  && ok "版本契约自洽 $(node -e "console.log(require('./contract.js').VERSION)")" || no "版本契约不自洽"
node -e "const c=require('./contract.js');process.exit(c.check('99.0.0').ok?1:0)" 2>/dev/null \
  && ok "版本不满足能被判否" || no "版本校验失效"
grep -q "FARM_IP_ECHO" farm.js && ok "FARM_IP_ECHO 开关" || no "FARM_IP_ECHO 缺失"
node -e "require.resolve('ws')" >/dev/null 2>&1 && ok "依赖 ws 可解析" || wn "ws 未安装（目标机执行 npm i ws 或设 NODE_PATH）"

echo "== 4. 台账结构 =="
TMP="$(mktemp -d)"; trap 'kill ${GPID:-} ${CPID:-} 2>/dev/null; sleep 0.5; rm -rf "$TMP" 2>/dev/null || { sleep 1.5; rm -rf "$TMP" 2>/dev/null; }' EXIT
cp farm.js control.js ledger.js driver.js contract.js camoufox_worker.py package.json "$TMP"/ 2>/dev/null
mkdir -p "$TMP/gateway" && cp gateway/server.js "$TMP/gateway/" 2>/dev/null
WS_PARENT="$(node -e "console.log(require('path').dirname(require('path').dirname(require.resolve('ws'))))" 2>/dev/null || true)"
[ -n "$WS_PARENT" ] && export NODE_PATH="$WS_PARENT"
cd "$TMP" || exit 2
export FARM_DB="$TMP/farm.db"
# 公开测试值，仅发往临时网关。通过 stdin 提供鉴权头，避免把令牌放进 argv。
export GATEWAY_TOKEN=T
unset FARM_TOKEN
auth_curl() { curl -H @- "$@" <<<"Authorization: Bearer $GATEWAY_TOKEN"; }
node -e "const l=require('./ledger.js');const s=l.stats();console.log(JSON.stringify(s))" >"$TMP/acc-db.json" 2>/dev/null \
  && ok "ledger 可打开 $(head -c 120 "$TMP/acc-db.json")" || no "ledger 打不开"
node -e "
const l=require('./ledger.js');
const cols=l.db.prepare('PRAGMA table_info(accounts)').all().map(c=>c.name);
const need=['fp_seed','engine','cdp'];
const miss=need.filter(x=>!cols.includes(x));
process.exit(miss.length?1:0)" 2>/dev/null && ok "accounts 含 fp_seed/engine/cdp" || no "台账缺 fp_seed/engine/cdp"

# ledger-clean.sh：dry-run 只列不删 / --apply 先备份再删 / 有 running 行必须拒绝
# 用 19672/19572 避开自检自己随后要占的 19671/19571，让三条断言与真网关状态无关
CLEAN_DB="$TMP/clean-test.db"
FARM_DB="$CLEAN_DB" node -e "require('./ledger.js')" >/dev/null 2>&1
sqlite3 "$CLEAN_DB" "INSERT INTO accounts (account,status,created_at,updated_at) VALUES ('probe:health:1','stopped','t','t'),('probe:health:2','stopped','t','t')"
CLEAN_OUT1="$(GATEWAY_PORT=19672 CONTROL_PORT=19572 bash "$SRC/scripts/ledger-clean.sh" --db "$CLEAN_DB" --account 'probe:health:%' 2>&1)"; CLEAN_RC1=$?
if [ "$CLEAN_RC1" -eq 0 ] && printf '%s' "$CLEAN_OUT1" | grep -q 'probe:health:1' \
   && [ "$(sqlite3 "$CLEAN_DB" 'SELECT count(*) FROM accounts')" = "2" ]; then
  ok "ledger-clean dry-run 只列不删（2 行）"
else
  no "ledger-clean dry-run 异常（EXIT=${CLEAN_RC1}）"
fi
CLEAN_OUT2="$(GATEWAY_PORT=19672 CONTROL_PORT=19572 bash "$SRC/scripts/ledger-clean.sh" --db "$CLEAN_DB" --account 'probe:health:%' --apply 2>&1)"; CLEAN_RC2=$?
CLEAN_BAK=0; for f in "$CLEAN_DB".bak-*; do [ -s "$f" ] && CLEAN_BAK=1; done
if [ "$CLEAN_RC2" -eq 0 ] && [ "$CLEAN_BAK" = "1" ] \
   && [ "$(sqlite3 "$CLEAN_DB" 'SELECT count(*) FROM accounts')" = "0" ]; then
  ok "ledger-clean --apply 备份后删除（2→0）"
else
  no "ledger-clean --apply 异常（EXIT=${CLEAN_RC2}）"
fi
sqlite3 "$CLEAN_DB" "INSERT INTO accounts (account,status,created_at,updated_at) VALUES ('live:acc','running','t','t')"
CLEAN_OUT3="$(GATEWAY_PORT=19672 CONTROL_PORT=19572 bash "$SRC/scripts/ledger-clean.sh" --db "$CLEAN_DB" --all-stopped --apply 2>&1)"; CLEAN_RC3=$?
if [ "$CLEAN_RC3" -ne 0 ] && printf '%s' "$CLEAN_OUT3" | grep -q 'running' \
   && [ "$(sqlite3 "$CLEAN_DB" 'SELECT count(*) FROM accounts')" = "1" ]; then
  ok "ledger-clean 拒删 running 行（EXIT=${CLEAN_RC3}）"
else
  no "ledger-clean 未拒绝 running 行（EXIT=${CLEAN_RC3}）"
fi

echo "== 5. 控制面 + 网关 =="
mkdir -p "$TMP/probe-tmp"
TMPDIR="$TMP/probe-tmp" node control.js --port "$ACCEPT_CONTROL_PORT" >"$TMP/acc-c.log" 2>&1 & CPID=$!
sleep 1
printf '%s\n' 'import sys; print("fixture: no worker response", file=sys.stderr)' >"$TMP/empty-worker.py"
cat >"$TMP/acceptance-worker.py" <<'PY'
import os
import sys

account = sys.argv[sys.argv.index('--account') + 1]
name = 'empty-worker.py' if account == 'default:acc-empty-worker' else 'camoufox_worker.py'
worker = os.path.join(os.path.dirname(__file__), name)
os.execv(sys.executable, [sys.executable, worker, *sys.argv[1:]])
PY
if [ -z "${CAMOUFOX_PY:-}" ] && [ -x "$HOME/.dsh/venvs/camoufox/bin/python" ]; then
  export CAMOUFOX_PY="$HOME/.dsh/venvs/camoufox/bin/python"
fi
node gateway/server.js --port "$ACCEPT_PORT" --control "http://127.0.0.1:$ACCEPT_CONTROL_PORT" --farm "$TMP/farm.js" --driver "$TMP/driver.js" \
  --camoufox-worker "$TMP/acceptance-worker.py" >"$TMP/acc-g.log" 2>&1 & GPID=$!
sleep 1.2
auth_curl -s "localhost:$ACCEPT_PORT/v1/health" >"$TMP/acc-h.json" 2>/dev/null \
  && grep -q '"gateway":"up"' "$TMP/acc-h.json" && ok "gateway /v1/health" || no "gateway /v1/health"
curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/sessions" | grep -qx 401 \
  && ok "未授权返回 401" || no "鉴权未生效"
auth_curl -s "localhost:$ACCEPT_PORT/v1/fingerprint/duplicates" >"$TMP/acc-d.json" 2>/dev/null \
  && grep -q 'distinct_canvas' "$TMP/acc-d.json" && ok "duplicates 可调用" || no "duplicates 不可用"
auth_curl -s "localhost:$ACCEPT_PORT/v1/version" >"$TMP/acc-v.json" 2>/dev/null \
  && grep -q '"contract_version":3[,}]' "$TMP/acc-v.json" && ok "版本契约 /v1/version" || no "/v1/version 不可用"
curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/version" | grep -qx 401 \
  && ok "/v1/version 需鉴权" || no "/v1/version 未鉴权"
auth_curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/version?require=99.0.0" | grep -qx 409 \
  && ok "版本不满足返回 409" || no "版本不满足未拦"
# probe=1 会真起浏览器，必须带 token；不带 probe 的 health 仍免鉴权
curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/health?probe=1" | grep -qx 401 \
  && ok "health?probe=1 需鉴权" || no "health?probe=1 未鉴权"

# 代理校验：带凭据 / 不支持 scheme 都必须在建会话前 400，且报错不回显 proxy 值
NEG1_CODE="$(auth_curl -s -o "$TMP/acc-p1.json" -w '%{http_code}' -X POST "localhost:$ACCEPT_PORT/v1/sessions" -H 'Idempotency-Key: acc-neg-proxy-cred' -H 'Content-Type: application/json' \
  -d '{"account":"neg-proxy","engine":"chromium","proxy":"http://user:secret@127.0.0.1:1080"}')"
if [ "$NEG1_CODE" = "400" ] && grep -q 'E_PROXY_CREDENTIALS' "$TMP/acc-p1.json" \
   && ! grep -q 'user:secret' "$TMP/acc-p1.json"; then
  ok "proxy 带凭据 → 400 E_PROXY_CREDENTIALS（不回显）"
else
  no "proxy 带凭据未被拦（HTTP=${NEG1_CODE}）"
fi
NEG2_CODE="$(auth_curl -s -o "$TMP/acc-p2.json" -w '%{http_code}' -X POST "localhost:$ACCEPT_PORT/v1/sessions" -H 'Idempotency-Key: acc-neg-proxy-scheme' -H 'Content-Type: application/json' \
  -d '{"account":"neg-proxy","engine":"chromium","proxy":"ftp://127.0.0.1:1"}')"
if [ "$NEG2_CODE" = "400" ] && grep -q 'E_PROXY_SCHEME' "$TMP/acc-p2.json"; then
  ok "proxy scheme 不支持 → 400 E_PROXY_SCHEME"
else
  no "proxy scheme 未被拦（HTTP=${NEG2_CODE}）"
fi
NEG_SESSIONS="$(auth_curl -s "localhost:$ACCEPT_PORT/v1/sessions")"
if ! printf '%s' "$NEG_SESSIONS" | grep -q 'neg-proxy'; then
  ok "proxy 两条负例未落台账（无 neg-proxy）"
else
  no "proxy 负例落进了台账：$(printf '%s' "$NEG_SESSIONS" | head -c 200)"
fi

# first-fetch.sh 负例：没配 PROXY_URL 必须 exit 2、不建会话（台账行数不变），提示指向 runbook
FF_DB="$TMP/first-fetch-neg.db"
FARM_DB="$FF_DB" node ledger.js stats >/dev/null 2>&1
FF_BEFORE="$(sqlite3 "$FF_DB" 'SELECT count(*) FROM accounts')"
FF_OUT="$(env -u PROXY_URL -u DSH_SECRET_PROXY_URL FARM_DB="$FF_DB" \
  bash "$SRC/scripts/first-fetch.sh" --platform amazon --query test --out "$TMP/ff-out" 2>&1)"; FF_RC=$?
FF_AFTER="$(sqlite3 "$FF_DB" 'SELECT count(*) FROM accounts')"
if [ "$FF_RC" -eq 2 ] && [ "$FF_BEFORE" = "$FF_AFTER" ] && printf '%s' "$FF_OUT" | grep -q 'data-fetch-runbook'; then
  ok "first-fetch 无 PROXY_URL → exit 2 且不建会话（台账 ${FF_BEFORE}→${FF_AFTER}）"
else
  no "first-fetch 负例异常（EXIT=$FF_RC 台账 ${FF_BEFORE}→${FF_AFTER}）"
fi

if [ "$WITH_BROWSER" = "1" ]; then
  echo "== 6. 真机冒烟（chromium 首检 + Camoufox 任务对齐）=="
  curl -s -X POST "localhost:$ACCEPT_CONTROL_PORT/instances" -H 'Content-Type: application/json' \
    -d '{"account":"acc-smoke","port":19499,"fp_seed":42,"tz":"Asia/Tokyo","lang":"ja-JP","platform":"accplat","headless":true}' >/dev/null
  sleep 1
  FARM_IP_ECHO="${FARM_IP_ECHO:-}" node farm.js check --account acc-smoke >"$TMP/acc-chk.json" 2>/dev/null
  grep -q '"ok": true' "$TMP/acc-chk.json" && ok "check 通过" || no "check 未通过"
  curl -s -X POST "localhost:$ACCEPT_CONTROL_PORT/instances/acc-smoke/check" >/dev/null
  [ -d "profiles/accplat/acc-smoke" ] && ok "profile 按平台分区（profiles/accplat/acc-smoke）" || no "profile 未按平台分区"
  curl -s "localhost:$ACCEPT_CONTROL_PORT/instances?platform=accplat" | grep -q '"acc-smoke"' \
    && ok "台账按 platform 可筛" || no "台账 platform 筛选失效"
  curl -s "localhost:$ACCEPT_CONTROL_PORT/instances?platform=nosuch" | grep -q '"instances": \[\]' \
    && ok "无关平台筛不到" || no "platform 筛选串了"
  GATEWAY_URL="http://127.0.0.1:$ACCEPT_PORT" node - "$SRC/mcp/farm-mcp.js" >"$TMP/acc-tasks.log" 2>&1 <<'NODE'
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { createServer } = require('node:net');
const { setTimeout: sleep } = require('node:timers/promises');
const base = process.env.GATEWAY_URL;
async function call(path, body) {
  const r = await fetch(base + path, {
    method: body ? 'POST' : 'GET',
    headers: { authorization: 'Bearer ' + process.env.GATEWAY_TOKEN,
      'content-type': 'application/json', 'idempotency-key': 'acceptance-' + (body?.account || 'task') },
    body: body && JSON.stringify(body), signal: AbortSignal.timeout(3000),
  });
  return [r.status, await r.json()];
}
function checkError(label, error, code) {
  assert.equal(error?.code, code, JSON.stringify(error));
  assert(typeof error.message === 'string' && error.message.trim());
  console.log(label, JSON.stringify(error));
}
async function submit(path, body, code) {
  const [status, task] = await call(path, body);
  assert.equal(status, 202, JSON.stringify(task));
  const expected = code ? 'failed' : 'succeeded';
  for (let i = 0; i < 150; i++) {
    const [status, result] = await call('/v1/tasks/' + task.task_id);
    assert.equal(status, 200);
    if (result.status !== 'queued' && result.status !== 'running') {
      assert.equal(result.status, expected, JSON.stringify(result));
      assert.equal(result.ok, !code);
      if (code) checkError('GET task ' + body.type, result.error, code);
      return result;
    }
    await sleep(100);
  }
  throw new Error('task did not finish before test deadline');
}
const cdp = '/v1/sessions/acc-smoke/tasks';
async function checkErrors() {
  const worker = '/v1/sessions/default:acc-empty-worker/tasks';
  const [unsupported, rejection] = await call(cdp, { type: 'unsupported' });
  assert.equal(unsupported, 422);
  checkError('POST unsupported', rejection.error, 'E_UNSUPPORTED_TASK');
  // 本地端点主动断开，稳定制造导航网络错误。
  const offline = createServer((socket) => socket.destroy());
  await new Promise((resolve) => offline.listen(0, '127.0.0.1', resolve));
  try {
    await submit(cdp, { type: 'goto', params: { url: 'http://127.0.0.1:' + offline.address().port } }, 'E_GOTO');
  } finally {
    offline.close();
  }
  await submit(cdp, { type: 'eval', params: { expr: '1+1' }, timeout_ms: 1 }, 'E_TIMEOUT');
  const [created, session] = await call('/v1/sessions', { account: 'acc-empty-worker', engine: 'camoufox', require_check: false });
  assert.equal(created, 201, JSON.stringify(session));
  const { task_id: taskId } = await submit(worker, { type: 'scan' }, 'E_WORKER_NO_OUTPUT');
  const input = [{ task_id: taskId }, { session_id: session.session_id, type: 'scan', wait_ms: 5000 }]
    .map((args, id) => JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'farm_task', arguments: args } }))
    .join('\n') + '\n';
  const mcp = spawnSync(process.execPath, [process.argv[2]], { input, encoding: 'utf8', timeout: 10000 });
  assert.equal(mcp.status, 0, mcp.stderr);
  const results = mcp.stdout.trim().split('\n').map(JSON.parse);
  assert.equal(results.length, 2);
  for (const { id, result } of results) {
    assert.equal(result.isError, true);
    checkError(id === 0 ? 'MCP query' : 'MCP poll', JSON.parse(result.content[0].text).error, 'E_WORKER_NO_OUTPUT');
  }
}
async function checkExtractParity() {
  const [created, session] = await call('/v1/sessions', { account: 'acc-extract-worker', engine: 'camoufox', require_check: false });
  assert.equal(created, 201, JSON.stringify(session));
  const worker = '/v1/sessions/' + encodeURIComponent(session.session_id) + '/tasks';
  const url = 'data:text/html,' + encodeURIComponent('<h1>  acceptance extract  </h1>');
  const params = { url, selector_map: { title: 'h1', missing: '#does-not-exist' }, timeout_ms: 2000 };
  const a = await submit(cdp, { type: 'extract', params });
  const b = await submit(worker, { type: 'extract', params });
  const envelope = ['ok', 'result', 'status', 'task_id'];
  assert.deepEqual(Object.keys(a).sort(), envelope);
  assert.deepEqual(Object.keys(b).sort(), envelope);
  assert.deepEqual(b.result, a.result);
  assert.deepEqual(b.result, { ok: false, url, fields: { title: 'acceptance extract', missing: null }, missing: ['missing'] });
}
async function checkWaitParity() {
  const [created, session] = await call('/v1/sessions', { account: 'acc-wait-worker', engine: 'camoufox', require_check: false });
  assert.equal(created, 201, JSON.stringify(session));
  const worker = '/v1/sessions/' + encodeURIComponent(session.session_id) + '/tasks';
  // worker 每个任务启动一次浏览器，直接在初始空页上等缺失的元素。
  const params = { selector: '#absent-on-blank-page', state: 'absent', timeout_ms: 1500 };
  const a = await submit(cdp, { type: 'wait', params });
  const b = await submit(worker, { type: 'wait', params });
  const envelope = ['ok', 'result', 'status', 'task_id'];
  assert.deepEqual(Object.keys(a).sort(), envelope);
  assert.deepEqual(Object.keys(b).sort(), envelope);
  const resultKeys = ['found', 'ok', 'selector', 'state', 'waited_ms'];
  assert.deepEqual(Object.keys(a.result).sort(), resultKeys);
  assert.deepEqual(Object.keys(b.result).sort(), resultKeys);
  const expected = { ok: true, found: false, state: params.state, selector: params.selector };
  for (const [key, value] of Object.entries(expected)) {
    assert.equal(a.result[key], value, `chromium wait ${key}`);
    assert.equal(b.result[key], a.result[key], `Camoufox wait ${key}`);
  }
}
(async () => {
  for (const [name, check] of [['wait', checkWaitParity], ['errors', checkErrors], ['extract', checkExtractParity]]) {
    try {
      await check();
      console.log('acceptance pass ' + name);
    } catch (e) {
      console.error(e);
      process.exitCode = 1;
    }
  }
})();
NODE
  sed '/^acceptance pass /d' "$TMP/acc-tasks.log"
  grep -Fxq 'acceptance pass errors' "$TMP/acc-tasks.log" \
    && ok "REST 与 MCP 任务失败返回结构化 error" || no "任务失败契约不符"
  grep -Fxq 'acceptance pass extract' "$TMP/acc-tasks.log" \
    && ok "Camoufox 与 chromium 的 extract 键集与任务信封一致" || no "extract 跨引擎契约不符"
  grep -Fxq 'acceptance pass wait' "$TMP/acc-tasks.log" \
    && ok "Camoufox 与 chromium 的 wait 结果同形" || no "wait 跨引擎契约不符"
  node farm.js stop --account acc-smoke >/dev/null 2>&1
  # MCP 适配层冒烟：stdio 喂 initialize → tools/list（断言 7 个工具）→ farm_health（断言 gateway up）
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"acceptance","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"farm_health","arguments":{}}}' \
    | GATEWAY_URL="http://127.0.0.1:$ACCEPT_PORT" node "$SRC/mcp/farm-mcp.js" >"$TMP/acc-mcp.jsonl" 2>/dev/null
  node -e '
const fs = require("fs");
const ls = fs.readFileSync("acc-mcp.jsonl", "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
const init = ls.find((x) => x.id === 1), list = ls.find((x) => x.id === 2), call = ls.find((x) => x.id === 3);
if (!init || !init.result || !init.result.serverInfo) process.exit(1);
if (!list || !list.result || !Array.isArray(list.result.tools) || list.result.tools.length !== 7) process.exit(2);
if (!call || !call.result || call.result.isError !== false) process.exit(3);
const body = JSON.parse(call.result.content[0].text);
if (body.gateway !== "up") process.exit(4);
' && ok "MCP stdio 冒烟（7 工具 + farm_health）" || no "MCP stdio 冒烟失败"
  PROBE_BEFORE="$(sqlite3 "$FARM_DB" 'SELECT count(*) FROM accounts')"
  auth_curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/health?probe=1" | grep -qx 200 \
    && ok "health?probe=1 带 token 可探" || no "health?probe=1 带 token 失败"
  PROBE_AFTER="$(sqlite3 "$FARM_DB" 'SELECT count(*) FROM accounts')"
  if [ -n "$PROBE_BEFORE" ] && [ "$PROBE_BEFORE" = "$PROBE_AFTER" ] \
    && [ -z "$(find profiles -name 'probe:health:*' -print)" ] \
    && [ -z "$(find "$TMP/probe-tmp" -name 'farm-health-*' -print)" ]; then
    ok "health 探针不留台账或 profile（账号 ${PROBE_BEFORE}→${PROBE_AFTER}）"
  else
    no "health 探针遗留台账或 profile（账号 ${PROBE_BEFORE}→${PROBE_AFTER}）"
  fi
else
  wn "跳过真机冒烟（加 --with-browser 启用）"
fi

kill $GPID $CPID 2>/dev/null; wait 2>/dev/null

echo
echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
[ "$FAIL" -eq 0 ] && echo "RESULT: READY" || echo "RESULT: NOT_READY"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
