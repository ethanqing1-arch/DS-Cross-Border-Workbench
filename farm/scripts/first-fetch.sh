#!/usr/bin/env bash
# =============================================================================
# first-fetch.sh — 代理到位后的「一条命令出第一页真数据」
#
# 用法：
#   PROXY_URL='socks5h://user:pass@host:1080' GATEWAY_TOKEN=... \
#     bash farm/scripts/first-fetch.sh --platform amazon --query 'wireless+earbuds' \
#     [--out <dir>] [--engine chromium|camoufox]
#
# 前置（三道检查）：
#   1) GATEWAY_TOKEN（或 DSH_SECRET_GATEWAY_TOKEN）缺失 → exit 2；长度 <32 记 WARN 照跑
#   2) PROXY_URL（或 DSH_SECRET_PROXY_URL）没配 → exit 2，绝不偷偷直连
#   3) 网关 /v1/health 不可达 → exit 2
#
# 流程：起桥（没起才起，只停自己起的）→ 探针（会话带 proxy）→ 打印 meta 摘要 → 台账残留提示
#
# 会话生命周期归探针，脚本不重复建：
#   farm-probe.js:433-435  建会话（带 --proxy / --engine，platform=probe）
#   farm-mcp.js:211        每次调用新生成 crypto.randomUUID() 作 Idempotency-Key
#   farm-probe.js:644-650  finally 里删会话（探针失败也删）
# 脚本自己再建一个会和探针 409 互踢，所以只把 --proxy 交给探针；下面的 trap 只做
# 「探针被 SIGKILL、finally 没跑到」时的兜底删除（按固定账号名）。
#
# 退出码：透传探针 0 ok / 2 blocked / 3 empty / 1 error；前置不满足返回 2。
# 边界：token 与代理值绝不打印、绝不经 argv；只停自己起的桥；不动台账历史行。
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || exit 2   # farm/
ROOT="$(cd "$SRC/.." 2>/dev/null && pwd)" || exit 2
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL 找不到 node（先 export PATH=\"/opt/homebrew/bin:\$PATH\"）" >&2; exit 2; }

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 2; }

PLATFORM=""
QUERY=""
OUT_DIR=""
ENGINE="chromium"
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --query)    QUERY="${2:-}";    shift 2 ;;
    --out)      OUT_DIR="${2:-}";  shift 2 ;;
    --engine)   ENGINE="${2:-}";   shift 2 ;;
    -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
    *) die "未知参数 $1（用 --help 看用法）" ;;
  esac
done
[ -n "$PLATFORM" ] || die "--platform 必填（如 amazon）"
[ -n "$QUERY" ] || die "--query 必填（空格写 + 或 %20，原样替换 {q}）"
case "$PLATFORM" in *[!a-zA-Z0-9_-]*) die "--platform 只允许字母数字/_/-（预设 id，不是路径）" ;; esac
case "$ENGINE" in chromium|camoufox) ;; *) die "--engine 只支持 chromium|camoufox" ;; esac
[ -f "$ROOT/distribution/connectors/farm-probe.js" ] || die "找不到探针：$ROOT/distribution/connectors/farm-probe.js"
[ -f "$SRC/proxy-bridge.js" ] || die "找不到代理桥：$SRC/proxy-bridge.js"
OUT_DIR="${OUT_DIR:-$ROOT/distribution/connectors/out}"
mkdir -p "$OUT_DIR" || die "产物目录建不出来：$OUT_DIR"

# ---- 前置 1：token（缺失是硬错，长度不足只 WARN） ----
TOKEN="${GATEWAY_TOKEN:-${DSH_SECRET_GATEWAY_TOKEN:-}}"
[ -n "$TOKEN" ] || die "GATEWAY_TOKEN 未设置（也可用 DSH_SECRET_GATEWAY_TOKEN）"
if [ "${#TOKEN}" -lt 32 ]; then
  warn "GATEWAY_TOKEN 长度 ${#TOKEN} < 32，建议换 openssl rand -hex 32 生成的 64 位串（本次照跑）"
fi

# ---- 前置 2：代理（没配就停，绝不偷偷直连） ----
PROXY_URL="${PROXY_URL:-${DSH_SECRET_PROXY_URL:-}}"
if [ -z "$PROXY_URL" ]; then
  die "PROXY_URL 未设置：本脚本不会偷偷直连。配置方法见 docs/data-fetch-runbook.md（美国出口：socks5h://user:pass@host:port）"
fi

# ---- 前置 3：网关 ----
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
GATEWAY_URL="${GATEWAY_URL%/}"
HEALTH_HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$GATEWAY_URL/v1/health" 2>/dev/null || true)"
[ "$HEALTH_HTTP" = "200" ] || die "网关不可达（GET $GATEWAY_URL/v1/health → ${HEALTH_HTTP:-无响应}）；先 bash farm/scripts/start-gateway.sh --daemon"

# ---- 桥：端口已听就复用，没听才起；只停自己起的 ----
BRIDGE_PORT=18080
BRIDGE_LOG="$OUT_DIR/bridge.log"
BRIDGE_PID=""
OWN_BRIDGE=0
port_open() {
  node -e '
    const net = require("net");
    const s = net.connect(Number(process.argv[1]), "127.0.0.1");
    const done = (c) => { try { s.destroy(); } catch (e) {} process.exit(c); };
    s.on("connect", () => done(0));
    s.on("error", () => done(1));
    setTimeout(() => done(1), 500);
  ' "$BRIDGE_PORT" >/dev/null 2>&1
}
if port_open; then
  warn "端口 $BRIDGE_PORT 已在监听：复用现有桥（无法确认它的上游是不是本次 PROXY_URL；不确定就先停掉再跑）"
else
  UPSTREAM_PROXY="$PROXY_URL" node "$SRC/proxy-bridge.js" --port "$BRIDGE_PORT" >>"$BRIDGE_LOG" 2>&1 &
  BRIDGE_PID=$!
  OWN_BRIDGE=1
  READY=0
  for _ in $(seq 1 50); do
    if port_open; then READY=1; break; fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      printf '桥启动退出，日志末 5 行：\n' >&2
      tail -5 "$BRIDGE_LOG" >&2 2>/dev/null || true
      die "代理桥启动失败（日志：$BRIDGE_LOG）"
    fi
    sleep 0.1
  done
  [ "$READY" = "1" ] || die "代理桥 5s 内未监听 127.0.0.1:$BRIDGE_PORT（日志：$BRIDGE_LOG）"
  say "桥已起 pid=$BRIDGE_PID port=$BRIDGE_PORT（只停自己起的）"
fi

# ---- 会话兜底清理（仅探针被硬杀时才有事可做） ----
ACCOUNT="first-fetch-$PLATFORM"
SESSION_TOUCHED=0
cleanup() {
  rc=$?
  if [ "$SESSION_TOUCHED" = "1" ] && [ -n "$TOKEN" ]; then
    printf 'header = "Authorization: Bearer %s"\nheader = "Idempotency-Key: %s"\n' "$TOKEN" "$(uuidgen)" \
      | curl -sS -K - -X DELETE --max-time 3 "$GATEWAY_URL/v1/sessions/default:$ACCOUNT" >/dev/null 2>&1 || true
  fi
  if [ "$OWN_BRIDGE" = "1" ] && [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---- 探针 ----
META="$OUT_DIR/$PLATFORM.jsonl.meta.json"
PROBE_OUT="$OUT_DIR/$PLATFORM.probe.json"
PROBE_ERR="$OUT_DIR/$PLATFORM.probe.err"
say "探针：platform=$PLATFORM engine=$ENGINE account=$ACCOUNT proxy=http://127.0.0.1:$BRIDGE_PORT（值不回显）"
SESSION_TOUCHED=1
node "$ROOT/distribution/connectors/farm-probe.js" \
  --platform "$PLATFORM" --query "$QUERY" --engine "$ENGINE" \
  --account "$ACCOUNT" --proxy "http://127.0.0.1:$BRIDGE_PORT" \
  --cache-bust --verbose --out "$OUT_DIR/$PLATFORM.jsonl" \
  >"$PROBE_OUT" 2>"$PROBE_ERR"
PROBE_RC=$?

if [ "$PROBE_RC" -ne 0 ]; then
  printf '探针 stderr 末 15 行：\n' >&2
  tail -15 "$PROBE_ERR" >&2 2>/dev/null || true
fi

# ---- meta 摘要：四态都要能解释「为什么没有数据」 ----
if [ -f "$META" ]; then
  node - "$META" <<'NODE'
const fs = require('fs');
const m = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
console.log('== meta ==');
console.log('status         ' + m.status);
console.log('item_count     ' + m.item_count);
console.log('transfer_size  ' + m.transfer_size);
console.log('final_url      ' + (m.final_url || '(none)'));
if (m.matched) console.log('matched        ' + JSON.stringify(m.matched));
if (m.error) console.log('error          ' + (m.error.code || '?') + ': ' + (m.error.message || ''));
NODE
else
  warn "没找到 meta：$META"
fi

# ---- 清理确认与台账残留提示 ----
CLEAN_OK="$(node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(String(o.cleanup&&o.cleanup.delete_ok))}catch(e){console.log("unknown")}' "$PROBE_OUT" 2>/dev/null)"
case "$CLEAN_OK" in
  true)  say "会话：已删（data_retained，台账保留 stopped 历史）" ;;
  false) warn "探针未确认删会话（cleanup.delete_ok=false）——查台账并手删：$ACCOUNT" ;;
  *)     say "会话：探针未建出会话（无需清理）" ;;
esac
if [ -n "${FARM_DB:-}" ] || [ -f "$SRC/state/farm.db" ]; then
  node - "$SRC/ledger.js" "default:$ACCOUNT" <<'NODE' 2>/dev/null || true
const l = require(process.argv[2]);
const acct = process.argv[3];
const rows = l.list().filter((r) => r.account === acct);
if (!rows.length) { console.log('台账：无本会话行'); process.exit(0); }
for (const r of rows) {
  const live = (r.status === 'running' || r.alive);
  console.log('台账：' + r.account + ' status=' + r.status + ' alive=' + r.alive +
    (live ? '  <- 仍在跑，先删会话再清' : '  （stopped 历史，设计如此）'));
  if (live) console.log('清理：bash farm/scripts/ledger-clean.sh --account \'' + acct + '\' --apply');
}
NODE
fi
say "产物：$OUT_DIR/$PLATFORM.jsonl（JSONL）/ $META（meta）"
say "RESULT: $([ "$PROBE_RC" -eq 0 ] && echo 'ok' || echo "exit=$PROBE_RC（0=ok 2=blocked 3=empty 1=error）")"
exit "$PROBE_RC"
