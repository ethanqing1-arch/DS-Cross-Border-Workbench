#!/usr/bin/env bash
# =============================================================================
# install.sh — dsh-ecom-l1（L1 核心包：browser-farm capability）
#
# 用法：
#   bash install.sh <目标目录>                     # 安装：校验并写标记文件
#   bash install.sh <目标目录> --check             # 只校验，不写任何文件
#   bash install.sh <目标目录> --farm <farm目录>   # 指定 farm 路径（默认 <仓库根>/farm）
#
# 环境变量：
#   GATEWAY_URL  默认 http://127.0.0.1:19671
#   FARM_DIR     同 --farm，命令行优先
#
# 边界：只写 <目标目录>/.dsh/ecom-l1.json；不打包 DS Bot、不写 secret、不碰 farm 台账与服务。
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/../.." && pwd)"
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

TARGET=""; CHECK=0; FARM_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --farm)
      shift
      [ $# -gt 0 ] || { echo "FAIL --farm 缺参数" >&2; exit 2; }
      FARM_ARG="$1"
      ;;
    -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "未知参数：$1（可用 --check / --farm <目录>）" >&2; exit 2 ;;
    *) if [ -z "$TARGET" ]; then TARGET="$1"; else echo "多余参数：$1" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$TARGET" ] || { echo "用法：bash install.sh <目标目录> [--check] [--farm <farm目录>]" >&2; exit 2; }

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
FARM="${FARM_ARG:-${FARM_DIR:-$ROOT/farm}}"
MARKER_REL=".dsh/ecom-l1.json"
MARKER="$TARGET/$MARKER_REL"

FAILED=0; WROTE=0; SKIPPED=0
ok()   { echo "  PASS $*"; }
bad()  { FAILED=$((FAILED+1)); echo "  FAIL $*"; }
warn() { echo "  WARN $*"; }

finish() {
  echo
  if [ "$CHECK" -eq 1 ]; then
    echo "== CHECK: would-write=$WROTE would-skip=$SKIPPED FAIL=$FAILED =="
    [ "$FAILED" -eq 0 ] && echo "CHECK OK（未写任何文件）" || echo "CHECK FAILED"
  else
    echo "== 汇总: write=$WROTE skip=$SKIPPED fail=$FAILED =="
    [ "$FAILED" -eq 0 ] && echo "INSTALL OK" || echo "INSTALL FAILED"
  fi
  [ "$FAILED" -eq 0 ] && exit 0 || exit 1
}

echo "== dsh-ecom-l1 $(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/manifest.json" 2>/dev/null | head -1) =="
echo "目标：$TARGET"
echo "farm：$FARM"
echo "模式：$([ "$CHECK" -eq 1 ] && echo '只校验（--check）' || echo '安装')"

# ---------------------------------------------------------------- 1. manifest
echo "-- 1. manifest"
if [ -f "$SRC/manifest.json" ] && node -e '
const m = require(process.argv[1]);
if (!m.name || !m.version || !m.requires || !m.requires["browser-farm"]) process.exit(1);
' "$SRC/manifest.json" 2>/dev/null; then
  ok "manifest 可解析（name/version/requires.browser-farm）"
else
  bad "manifest 不可解析或字段不全"
fi

# ---------------------------------------------------------------- 2. node
echo "-- 2. node 绝对路径"
NODE_BIN="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE_BIN" ]; then
  bad "找不到 node（PATH 里缺 /opt/homebrew/bin？）"
elif [ "${NODE_BIN#/}" = "$NODE_BIN" ]; then
  bad "node 不是绝对路径：$NODE_BIN"
elif "$NODE_BIN" -e 'process.exit(0)' >/dev/null 2>&1; then
  ok "node 可执行且为绝对路径：$NODE_BIN"
else
  bad "node 不可执行：$NODE_BIN"
fi

# ---------------------------------------------------------------- 3. farm 适配层
echo "-- 3. farm 与 stdio 适配层"
MCP="$FARM/mcp/farm-mcp.js"
if [ -f "$MCP" ]; then
  ok "farm-mcp.js 存在：$MCP"
  if [ -n "$NODE_BIN" ] && "$NODE_BIN" --check "$MCP" >/dev/null 2>&1; then
    ok "farm-mcp.js 语法通过（node --check）"
  else
    bad "farm-mcp.js 语法不通过"
  fi
else
  bad "farm-mcp.js 不存在：$MCP"
fi

# ---------------------------------------------------------------- 4. capability 载荷
echo "-- 4. capability 载荷"
CAP="$SRC/capability/browser-farm.json"
CAP_OK=0
if [ -f "$CAP" ]; then
  if CAP_PATH="$CAP" MCP_PATH="$MCP" NODE_BIN="$NODE_BIN" node -e '
const fs = require("fs");
const c = JSON.parse(fs.readFileSync(process.env.CAP_PATH, "utf8"));
const errs = [];
if (c.name !== "browser-farm") errs.push("name=" + c.name);
if (c.kind !== "mcp") errs.push("kind=" + c.kind);
if (c.transport !== "stdio") errs.push("transport=" + c.transport);
if (!Array.isArray(c.args) || !c.args[0]) errs.push("args 缺失");
if (c.command !== process.env.NODE_BIN) errs.push("command=" + c.command + " 与本机 node " + process.env.NODE_BIN + " 不一致");
if (c.args && c.args[0] && c.args[0] !== process.env.MCP_PATH) errs.push("args[0] 未指向当前 farm：" + c.args[0]);
if (((c.env || {}).GATEWAY_TOKEN || "") !== "$DSH_SECRET_GATEWAY_TOKEN") errs.push("env.GATEWAY_TOKEN 不是 $DSH_SECRET_GATEWAY_TOKEN 占位，疑似明文 secret");
if (errs.length) { for (const e of errs) console.log("  FAIL " + e); process.exit(1); }
process.exit(0);
' 2>&1; then
    CAP_OK=1
  else
    :
  fi
  if [ "$CAP_OK" -eq 1 ]; then
    ok "载荷字段齐（name/kind/transport/command/args/env）"
    ok "env.GATEWAY_TOKEN 只是 \$DSH_SECRET_GATEWAY_TOKEN 占位，无明文 secret"
  else
    bad "capability 载荷校验不通过（见上行原因）"
  fi
else
  bad "缺 capability/browser-farm.json"
fi

# ---------------------------------------------------------------- 5. 品牌占位
echo "-- 5. 品牌占位"
if [ -f "$SRC/branding/brand.json" ] && node -e '
const b = require(process.argv[1]);
if (!b.id || !b.name || !b.colors || !b.icon || !b.icon.path) process.exit(1);
' "$SRC/branding/brand.json" 2>/dev/null; then
  ok "brand.json 可解析（id/name/colors/icon.path）"
  if [ -f "$SRC/branding/assets/.gitkeep" ]; then
    ok "assets/ 是空占位（只有 .gitkeep）"
  else
    bad "缺 branding/assets/.gitkeep"
  fi
  N="$(find "$SRC/branding/assets" -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$N" -eq 0 ] && ok "assets/ 未拷入任何现成资产" || bad "assets/ 有 $N 个非占位文件（应为 0）"
else
  bad "brand.json 不可解析或缺字段"
fi

# ---------------------------------------------------------------- 6. 网关可达
echo "-- 6. 网关可达（只读 /v1/health）"
GW_CODE="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "${GATEWAY_URL%/}/v1/health" 2>/dev/null || true)"
if [ "$GW_CODE" = "200" ]; then
  ok "网关可达：$GATEWAY_URL（/v1/health 200）"
else
  warn "网关不可达或未就绪（$GATEWAY_URL HTTP=${GW_CODE:-无}），只 WARN 不挡安装"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAIL 前置校验未过，不写标记文件"
  finish
fi

# ---------------------------------------------------------------- 7. 标记文件
echo "-- 7. 标记文件"
NEW_JSON="$(MANIFEST="$SRC/manifest.json" CAP="$CAP" FARM_PATH="$FARM" NODE_PATH="$NODE_BIN" GW_URL="$GATEWAY_URL" node -e '
const fs = require("fs");
const mf = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
const cap = JSON.parse(fs.readFileSync(process.env.CAP, "utf8"));
const out = {
  marker: "ecom-l1",
  name: mf.name,
  version: mf.version,
  capability: cap.name,
  capability_kind: cap.kind,
  capability_transport: cap.transport,
  farm: process.env.FARM_PATH,
  node: process.env.NODE_PATH,
  gateway_url: process.env.GW_URL,
  mcp: cap.args[0]
};
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
')"
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$NEW_JSON" ]; then
  echo "  skip      $MARKER_REL（已存在且一致）"; SKIPPED=$((SKIPPED+1))
elif [ "$CHECK" -eq 1 ]; then
  echo "  missing   $MARKER_REL（安装时会写）"; WROTE=$((WROTE+1))
else
  if mkdir -p "$TARGET/.dsh" && printf '%s' "$NEW_JSON" > "$MARKER"; then
    echo "  write     $MARKER_REL"; WROTE=$((WROTE+1))
  else
    echo "  FAIL      $MARKER_REL"; FAILED=$((FAILED+1))
  fi
fi

# ---------------------------------------------------------------- 8. 注册步骤
if [ "$FAILED" -eq 0 ] && [ "$CHECK" -eq 0 ] && [ "$WROTE" -gt 0 ]; then
  echo "-- 8. 注册与 Allow 步骤"
  cat <<'STEPS'
  1) 起网关（令牌只从环境变量，不进 argv）：
       GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash farm/scripts/start-gateway.sh --daemon
  2) 注册共享能力 browser-farm（载荷原文见 capability/browser-farm.json）：
       kind=mcp   transport=stdio
       command=<node 绝对路径>
       args=[<仓库>/farm/mcp/farm-mcp.js]
       env={GATEWAY_URL=<网关地址>, GATEWAY_TOKEN=$DSH_SECRET_GATEWAY_TOKEN}
       注意：env 里的 token 只是占位符，真值由 DSH 注入，不要写成明文。
  3) 用户本人放行：Settings → Capabilities → Shared capabilities → browser-farm → Allow
  4) 验 7 个工具：tools/list 应见 farm_health / farm_version / farm_sessions /
     farm_session_create / farm_session_delete / farm_task / farm_fingerprint_verify
  5) 收尾：farm_health 应回 ok:true；farm_version 带 require=1.1.0 应 PASS
STEPS
fi

finish
