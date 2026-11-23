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
         scripts/mock-ip-echo.js scripts/verify-dual-env.sh scripts/test-proxy-bridge.sh scripts/proxy-selftest.sh scripts/ledger-clean.sh camoufox_worker.py \
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
cp farm.js control.js ledger.js driver.js contract.js package.json "$TMP"/ 2>/dev/null
mkdir -p "$TMP/gateway" && cp gateway/server.js "$TMP/gateway/" 2>/dev/null
WS_PARENT="$(node -e "console.log(require('path').dirname(require('path').dirname(require.resolve('ws'))))" 2>/dev/null || true)"
[ -n "$WS_PARENT" ] && export NODE_PATH="$WS_PARENT"
cd "$TMP" || exit 2
node -e "const l=require('./ledger.js');const s=l.stats();console.log(JSON.stringify(s))" >/tmp/acc-db.json 2>/dev/null \
  && ok "ledger 可打开 $(head -c 120 /tmp/acc-db.json)" || no "ledger 打不开"
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
  no "ledger-clean dry-run 异常（EXIT=$CLEAN_RC1）"
fi
CLEAN_OUT2="$(GATEWAY_PORT=19672 CONTROL_PORT=19572 bash "$SRC/scripts/ledger-clean.sh" --db "$CLEAN_DB" --account 'probe:health:%' --apply 2>&1)"; CLEAN_RC2=$?
CLEAN_BAK=0; for f in "$CLEAN_DB".bak-*; do [ -s "$f" ] && CLEAN_BAK=1; done
if [ "$CLEAN_RC2" -eq 0 ] && [ "$CLEAN_BAK" = "1" ] \
   && [ "$(sqlite3 "$CLEAN_DB" 'SELECT count(*) FROM accounts')" = "0" ]; then
  ok "ledger-clean --apply 备份后删除（2→0）"
else
  no "ledger-clean --apply 异常（EXIT=$CLEAN_RC2）"
fi
sqlite3 "$CLEAN_DB" "INSERT INTO accounts (account,status,created_at,updated_at) VALUES ('live:acc','running','t','t')"
CLEAN_OUT3="$(GATEWAY_PORT=19672 CONTROL_PORT=19572 bash "$SRC/scripts/ledger-clean.sh" --db "$CLEAN_DB" --all-stopped --apply 2>&1)"; CLEAN_RC3=$?
if [ "$CLEAN_RC3" -ne 0 ] && printf '%s' "$CLEAN_OUT3" | grep -q 'running' \
   && [ "$(sqlite3 "$CLEAN_DB" 'SELECT count(*) FROM accounts')" = "1" ]; then
  ok "ledger-clean 拒删 running 行（EXIT=$CLEAN_RC3）"
else
  no "ledger-clean 未拒绝 running 行（EXIT=$CLEAN_RC3）"
fi

echo "== 5. 控制面 + 网关 =="
node control.js --port "$ACCEPT_CONTROL_PORT" >/tmp/acc-c.log 2>&1 & CPID=$!
sleep 1
node gateway/server.js --port "$ACCEPT_PORT" --control "http://127.0.0.1:$ACCEPT_CONTROL_PORT" --token T   --farm "$TMP/farm.js" --driver "$TMP/driver.js" >/tmp/acc-g.log 2>&1 & GPID=$!
sleep 1.2
curl -s -H 'Authorization: Bearer T' "localhost:$ACCEPT_PORT/v1/health" >/tmp/acc-h.json 2>/dev/null \
  && grep -q '"gateway":"up"' /tmp/acc-h.json && ok "gateway /v1/health" || no "gateway /v1/health"
curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/sessions" | grep -qx 401 \
  && ok "未授权返回 401" || no "鉴权未生效"
curl -s -H 'Authorization: Bearer T' "localhost:$ACCEPT_PORT/v1/fingerprint/duplicates" >/tmp/acc-d.json 2>/dev/null \
  && grep -q 'distinct_canvas' /tmp/acc-d.json && ok "duplicates 可调用" || no "duplicates 不可用"
curl -s -H 'Authorization: Bearer T' "localhost:$ACCEPT_PORT/v1/version" >/tmp/acc-v.json 2>/dev/null \
  && grep -q '"contract_version"' /tmp/acc-v.json && ok "版本契约 /v1/version" || no "/v1/version 不可用"
curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/version" | grep -qx 401 \
  && ok "/v1/version 需鉴权" || no "/v1/version 未鉴权"
curl -s -o /dev/null -w "%{http_code}" -H 'Authorization: Bearer T' "localhost:$ACCEPT_PORT/v1/version?require=99.0.0" | grep -qx 409 \
  && ok "版本不满足返回 409" || no "版本不满足未拦"
# probe=1 会真起浏览器，必须带 token；不带 probe 的 health 仍免鉴权
curl -s -o /dev/null -w "%{http_code}" "localhost:$ACCEPT_PORT/v1/health?probe=1" | grep -qx 401 \
  && ok "health?probe=1 需鉴权" || no "health?probe=1 未鉴权"

# 代理校验：带凭据 / 不支持 scheme 都必须在建会话前 400，且报错不回显 proxy 值
NEG1_CODE="$(curl -s -o /tmp/acc-p1.json -w '%{http_code}' -X POST "localhost:$ACCEPT_PORT/v1/sessions" \
  -H 'Authorization: Bearer T' -H 'Idempotency-Key: acc-neg-proxy-cred' -H 'Content-Type: application/json' \
  -d '{"account":"neg-proxy","engine":"chromium","proxy":"http://user:secret@127.0.0.1:1080"}')"
if [ "$NEG1_CODE" = "400" ] && grep -q 'E_PROXY_CREDENTIALS' /tmp/acc-p1.json \
   && ! grep -q 'user:secret' /tmp/acc-p1.json; then
  ok "proxy 带凭据 → 400 E_PROXY_CREDENTIALS（不回显）"
else
  no "proxy 带凭据未被拦（HTTP=$NEG1_CODE）"
fi
NEG2_CODE="$(curl -s -o /tmp/acc-p2.json -w '%{http_code}' -X POST "localhost:$ACCEPT_PORT/v1/sessions" \
  -H 'Authorization: Bearer T' -H 'Idempotency-Key: acc-neg-proxy-scheme' -H 'Content-Type: application/json' \
  -d '{"account":"neg-proxy","engine":"chromium","proxy":"ftp://127.0.0.1:1"}')"
if [ "$NEG2_CODE" = "400" ] && grep -q 'E_PROXY_SCHEME' /tmp/acc-p2.json; then
  ok "proxy scheme 不支持 → 400 E_PROXY_SCHEME"
else
  no "proxy scheme 未被拦（HTTP=$NEG2_CODE）"
fi
NEG_SESSIONS="$(curl -s -H 'Authorization: Bearer T' "localhost:$ACCEPT_PORT/v1/sessions")"
if ! printf '%s' "$NEG_SESSIONS" | grep -q 'neg-proxy'; then
  ok "proxy 两条负例未落台账（无 neg-proxy）"
else
  no "proxy 负例落进了台账：$(printf '%s' "$NEG_SESSIONS" | head -c 200)"
fi

if [ "$WITH_BROWSER" = "1" ]; then
  echo "== 6. 真机冒烟（起 chromium + 首检 + 任务）=="
  curl -s -X POST "localhost:$ACCEPT_CONTROL_PORT/instances" -H 'Content-Type: application/json' \
    -d '{"account":"acc-smoke","port":19499,"fp_seed":42,"tz":"Asia/Tokyo","lang":"ja-JP","platform":"accplat","headless":true}' >/dev/null
  sleep 1
  FARM_IP_ECHO="${FARM_IP_ECHO:-}" node farm.js check --account acc-smoke >/tmp/acc-chk.json 2>/dev/null
  grep -q '"ok": true' /tmp/acc-chk.json && ok "check 通过" || no "check 未通过"
  curl -s -X POST "localhost:$ACCEPT_CONTROL_PORT/instances/acc-smoke/check" >/dev/null
  [ -d "profiles/accplat/acc-smoke" ] && ok "profile 按平台分区（profiles/accplat/acc-smoke）" || no "profile 未按平台分区"
  curl -s "localhost:$ACCEPT_CONTROL_PORT/instances?platform=accplat" | grep -q '"acc-smoke"' \
    && ok "台账按 platform 可筛" || no "台账 platform 筛选失效"
  curl -s "localhost:$ACCEPT_CONTROL_PORT/instances?platform=nosuch" | grep -q '"instances": \[\]' \
    && ok "无关平台筛不到" || no "platform 筛选串了"
  node farm.js stop --account acc-smoke >/dev/null 2>&1
  # MCP 适配层冒烟：stdio 喂 initialize → tools/list（断言 7 个工具）→ farm_health（断言 gateway up）
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"acceptance","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"farm_health","arguments":{}}}' \
    | GATEWAY_URL="http://127.0.0.1:$ACCEPT_PORT" GATEWAY_TOKEN=T node "$SRC/mcp/farm-mcp.js" >/tmp/acc-mcp.jsonl 2>/dev/null
  node -e '
const fs = require("fs");
const ls = fs.readFileSync("/tmp/acc-mcp.jsonl", "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
const init = ls.find((x) => x.id === 1), list = ls.find((x) => x.id === 2), call = ls.find((x) => x.id === 3);
if (!init || !init.result || !init.result.serverInfo) process.exit(1);
if (!list || !list.result || !Array.isArray(list.result.tools) || list.result.tools.length !== 7) process.exit(2);
if (!call || !call.result || call.result.isError !== false) process.exit(3);
const body = JSON.parse(call.result.content[0].text);
if (body.gateway !== "up") process.exit(4);
' && ok "MCP stdio 冒烟（7 工具 + farm_health）" || no "MCP stdio 冒烟失败"
  curl -s -o /dev/null -w "%{http_code}" -H 'Authorization: Bearer T' "localhost:$ACCEPT_PORT/v1/health?probe=1" | grep -qx 200 \
    && ok "health?probe=1 带 token 可探" || no "health?probe=1 带 token 失败"
else
  wn "跳过真机冒烟（加 --with-browser 启用）"
fi

kill $GPID $CPID 2>/dev/null; wait 2>/dev/null

echo
echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
[ "$FAIL" -eq 0 ] && echo "RESULT: READY" || echo "RESULT: NOT_READY"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
