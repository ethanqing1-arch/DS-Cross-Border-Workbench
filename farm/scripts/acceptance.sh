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
for f in farm.js control.js ledger.js driver.js contract.js gateway/server.js docker/Dockerfile docker/entry.sh \
         scripts/mock-ip-echo.js scripts/verify-dual-env.sh camoufox_worker.py \
         docs/dsbot-workbench-architecture.md docs/dsbot-workbench-review.md; do
  [ -f "$f" ] && ok "$f" || no "缺文件 $f"
done

echo "== 2. 语法 =="
for f in farm.js control.js ledger.js driver.js contract.js gateway/server.js scripts/mock-ip-echo.js; do
  node --check "$f" 2>/dev/null && ok "node --check $f" || no "语法错 $f"
done
python3 -c "import ast;ast.parse(open('camoufox_worker.py').read())" 2>/dev/null && ok "camoufox_worker.py" || no "camoufox_worker.py 语法错"
bash -n scripts/verify-dual-env.sh 2>/dev/null && ok "verify-dual-env.sh" || no "verify-dual-env.sh 语法错"

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
else
  wn "跳过真机冒烟（加 --with-browser 启用）"
fi

kill $GPID $CPID 2>/dev/null; wait 2>/dev/null

echo
echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
[ "$FAIL" -eq 0 ] && echo "RESULT: READY" || echo "RESULT: NOT_READY"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
