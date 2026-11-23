#!/usr/bin/env bash
# =============================================================================
# verify.sh — dsh-ecom 三层总装验收（一条命令）
#
# 用法：
#   bash verify.sh            # 跑完清掉临时目录
#   bash verify.sh --keep     # 保留临时目录，便于事后看现场
#
# 流程：临时目录里依次 L2 → 7 个平台 → 全量 --check → 空目录负例（必须 FAIL 且 0 写入），
#       最后打 PASS/FAIL/WARN 汇总、RESULT 与退出码（0 / 1）。
#
# 边界：只写 mktemp 目录；不碰 ~/ds-bot-workspace、不碰 DS Bot 状态、不碰 farm。
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（可用 --keep）" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); echo "  PASS $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
warn() { WARN=$((WARN+1)); echo "  WARN $*"; }

TMP="$(mktemp -d /tmp/dsh-ecom-verify.XXXXXX)" || { echo "FAIL 无法创建临时目录"; exit 2; }
WS="$TMP/workspace"
cleanup() {
  if [ "$KEEP" -eq 1 ]; then
    echo
    echo "临时目录保留：$TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

echo "== dsh-ecom 三层总装验收 =="
echo "仓库：$ROOT"
echo "临时根目录：$TMP"

# ---------------------------------------------------------------- 0. 入口文件
echo "-- 0. 入口文件"
for f in "l2/install.sh" "l2/manifest.json" "l3/install.sh" "l3/manifest.json" "l3/schema/platform.schema.json"; do
  if [ -f "$SRC/$f" ]; then ok "存在 $f"; else bad "缺 $f"; fi
done
if [ "$FAIL" -ne 0 ]; then
  echo
  echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
  echo "RESULT: NOT_READY（入口不全，后续未跑）"
  exit 1
fi

REAL_WS="$HOME/ds-bot-workspace"
REAL_MTIME=""
if [ -d "$REAL_WS" ]; then
  REAL_MTIME="$(stat -f %m "$REAL_WS" 2>/dev/null || stat -c %Y "$REAL_WS" 2>/dev/null || true)"
  [ -n "$REAL_MTIME" ] || warn "读不到 ~/ds-bot-workspace 的 mtime，跳过边界校验"
else
  warn "本机没有 ~/ds-bot-workspace，跳过边界校验"
fi

# ---------------------------------------------------------------- 1. L2
echo "-- 1. L2 版本包 dsh-ecom-cbec"
OUT="$(bash "$SRC/l2/install.sh" "$WS" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -E '^(== 汇总|INSTALL)' | sed 's/^/    /'
[ "$RC" -eq 0 ] && ok "L2 install 退出码 0" || bad "L2 install 退出码 $RC"
if printf '%s' "$OUT" | grep -q '== 汇总: write=53 skip=0 fail=0 =='; then
  ok "L2 汇总 write=53 skip=0 fail=0"
else
  bad "L2 汇总不符：$(printf '%s\n' "$OUT" | grep '== 汇总' | tail -1 || echo 无汇总行)"
fi
FILES="$(find "$WS" -type f | wc -l | tr -d ' ')"
[ "$FILES" -eq 30 ] && ok "L2 落点文件数 30" || bad "L2 落点文件数 $FILES（期望 30）"
SK="$(find "$WS/.dsh/skills" -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
[ "$SK" -eq 4 ] && ok "L2 skills=4" || bad "L2 skills=$SK（期望 4）"

# ---------------------------------------------------------------- 2. 平台逐个装
echo "-- 2. L3 平台包（逐个装）"
PLATFORMS="$(bash "$SRC/l3/install.sh" --list | awk 'NR>1 {print $1}')"
PCOUNT="$(printf '%s\n' "$PLATFORMS" | grep -c .)"
[ "$PCOUNT" -eq 7 ] && ok "平台清单 7 个" || bad "平台清单 $PCOUNT 个（期望 7）"
for p in $PLATFORMS; do
  OUT="$(bash "$SRC/l3/install.sh" "$p" "$WS" 2>&1)"; RC=$?
  W="$(printf '%s\n' "$OUT" | sed -n 's/^== 汇总: write=\([0-9]*\) skip=\([0-9]*\) fail=\([0-9]*\) ==/\1 \2 \3/p' | tail -1)"
  LANDED="$(find "$WS/95-engine/platforms/$p" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$RC" -eq 0 ] && [ "$W" = "4 0 0" ] && [ "$LANDED" -eq 4 ]; then
    ok "平台 $p 安装（write=4 skip=0 fail=0，落点 4）"
  else
    bad "平台 $p 安装（rc=$RC 汇总='${W:-无}' 落点=$LANDED）"
  fi
done
DIRS="$(find "$WS/95-engine/platforms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$DIRS" -eq 7 ] && ok "平台落点目录 7 个" || bad "平台落点目录 $DIRS 个（期望 7）"

# ---------------------------------------------------------------- 3. 全量 --check
echo "-- 3. 全量 --check（不写）"
SUM_BEFORE="$(cd "$WS" && find . -type f | sort | xargs shasum | shasum | cut -d' ' -f1)"
for p in $PLATFORMS; do
  OUT="$(bash "$SRC/l3/install.sh" "$p" "$WS" --check 2>&1)"; RC=$?
  LINE="$(printf '%s\n' "$OUT" | grep '^== CHECK' | tail -1)"
  if [ "$RC" -eq 0 ] && printf '%s' "$LINE" | grep -q 'would-write=0 '; then
    ok "平台 $p --check 幂等（$LINE）"
  else
    bad "平台 $p --check（rc=$RC ${LINE:-无 CHECK 行}）"
  fi
done
SUM_AFTER="$(cd "$WS" && find . -type f | sort | xargs shasum | shasum | cut -d' ' -f1)"
if [ "$SUM_BEFORE" = "$SUM_AFTER" ]; then
  ok "--check 未改任何文件（shasum 一致 ${SUM_BEFORE:0:12}…）"
else
  bad "--check 改了文件（$SUM_BEFORE -> $SUM_AFTER）"
fi

# ---------------------------------------------------------------- 4. 空目录负例
echo "-- 4. 负例：空目录装平台必须 FAIL 且 0 写入"
E="$TMP/empty"
mkdir -p "$E"
OUT="$(bash "$SRC/l3/install.sh" ebay "$E" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "空目录装 ebay 退出码 $RC（非 0）" || bad "空目录装 ebay 退出码 0（应 FAIL）"
printf '%s' "$OUT" | grep -q 'FAIL 目标目录未装 L2' \
  && ok "空目录失败原因正确（未装 L2）" \
  || bad "空目录失败原因不符：$(printf '%s\n' "$OUT" | grep FAIL | tail -1 || echo 无 FAIL 行)"
EFILES="$(find "$E" -type f | wc -l | tr -d ' ')"
[ "$EFILES" -eq 0 ] && ok "空目录 0 写入" || bad "空目录写了 $EFILES 个文件"

# ---------------------------------------------------------------- 5. 边界
if [ -n "$REAL_MTIME" ]; then
  NOW="$(stat -f %m "$REAL_WS" 2>/dev/null || stat -c %Y "$REAL_WS" 2>/dev/null || true)"
  if [ "$NOW" = "$REAL_MTIME" ]; then
    ok "真工作区未被写（mtime 未变）"
  else
    bad "真工作区 mtime 变了（$REAL_MTIME -> $NOW）"
  fi
fi

# ---------------------------------------------------------------- 汇总
echo
echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: READY"
  exit 0
else
  echo "RESULT: NOT_READY"
  exit 1
fi
