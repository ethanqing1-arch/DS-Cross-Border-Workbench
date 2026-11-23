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
# macOS Bash 3.2 在 UTF-8 locale 下可能把变量后的全角标点读进变量名。
export LC_ALL=C

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${arg}（可用 --keep）" >&2; exit 2 ;;
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
for f in "l1/install.sh" "l1/manifest.json" "l1/capability/browser-farm.json" "l2/install.sh" "l2/manifest.json" "l3/install.sh" "l3/manifest.json" "l3/schema/platform.schema.json"; do
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

# ---------------------------------------------------------------- 1. L1
echo "-- 1. L1 核心包 dsh-ecom-l1"
L1T="$TMP/l1"
OUT="$(bash "$SRC/l1/install.sh" "$L1T" 2>&1)"; RC=$?
W="$(printf '%s\n' "$OUT" | sed -n 's/^== 汇总: write=\([0-9]*\) skip=\([0-9]*\) fail=\([0-9]*\) ==/\1 \2 \3/p' | tail -1)"
# L1 只写 .dsh/ecom-l1.json，首次安装恒为 1 次写入。
if [ "$RC" -eq 0 ] && [ "$W" = "1 0 0" ]; then
  ok "L1 install（write=1 skip=0 fail=0）"
else
  bad "L1 install（rc=$RC 汇总='${W:-无}'）"
fi
if printf '%s' "$OUT" | grep -q 'WARN 网关不可达'; then
  warn "L1 网关不可达（安装器只 WARN，未挡安装）"
fi
MARKER="$L1T/.dsh/ecom-l1.json"
if [ -f "$MARKER" ] && node -e '
const m = require(process.argv[1]);
if (m.name !== "dsh-ecom-l1" || m.capability !== "browser-farm") process.exit(1);
' "$MARKER" 2>/dev/null; then
  ok "L1 标记文件可解析（name=dsh-ecom-l1 capability=browser-farm）"
else
  bad "L1 标记文件缺失或不可解析"
fi
L1SUM1="$(shasum "$MARKER" 2>/dev/null | cut -d' ' -f1)"
OUT="$(bash "$SRC/l1/install.sh" "$L1T" --check 2>&1)"; RC=$?
LINE="$(printf '%s\n' "$OUT" | grep '^== CHECK' | tail -1)"
L1SUM2="$(shasum "$MARKER" 2>/dev/null | cut -d' ' -f1)"
if [ "$RC" -eq 0 ] && printf '%s' "$LINE" | grep -q 'would-write=0 '; then
  ok "L1 --check 幂等（${LINE}）"
else
  bad "L1 --check（rc=$RC ${LINE:-无 CHECK 行}）"
fi
if [ -z "$L1SUM1" ] || [ -z "$L1SUM2" ]; then
  bad "L1 --check 后标记文件缺失或读不到 shasum"
elif [ "$L1SUM1" = "$L1SUM2" ]; then
  ok "L1 --check 未改标记文件（shasum 一致 ${L1SUM1:0:12}…）"
else
  bad "L1 --check 改了标记文件（$L1SUM1 -> ${L1SUM2}）"
fi
L1NEG="$TMP/l1-negative"; EMPTY_FARM="$TMP/empty-farm"
mkdir -p "$L1NEG" "$EMPTY_FARM"
OUT="$(bash "$SRC/l1/install.sh" "$L1NEG" --farm "$EMPTY_FARM" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "L1 负例 --farm 空目录退出码 ${RC}（非 0）" || bad "L1 负例 --farm 空目录退出码 0（应 FAIL）"
printf '%s' "$OUT" | grep -q 'farm-mcp.js 不存在' \
  && ok "L1 负例失败原因正确（farm-mcp.js 不存在）" \
  || bad "L1 负例失败原因不符"
L1NFILES="$(find "$L1NEG" -type f | wc -l | tr -d ' ')"
[ "$L1NFILES" -eq 0 ] && ok "L1 负例目标 0 写入" || bad "L1 负例目标写了 $L1NFILES 个文件"

# ---------------------------------------------------------------- 2. L2
echo "-- 2. L2 版本包 dsh-ecom-cbec"
L2_WORKSPACE="$SRC/l2/workspace"
L2_SKILLS="$SRC/l2/skills"
L2_FILES="$(find "$L2_WORKSPACE" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')"
L2_DIRS="$(find "$L2_WORKSPACE" -mindepth 1 -type d | wc -l | tr -d ' ')"
L2_SKILL_FILES="$(find "$L2_SKILLS" -mindepth 2 -type f | wc -l | tr -d ' ')"
EXPECTED_FILES=$((L2_FILES+L2_SKILL_FILES))
EXPECTED_WRITES=$((EXPECTED_FILES+L2_DIRS))
OUT="$(bash "$SRC/l2/install.sh" "$WS" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -E '^(== 汇总|INSTALL)' | sed 's/^/    /'
[ "$RC" -eq 0 ] && ok "L2 install 退出码 0" || bad "L2 install 退出码 $RC"
if printf '%s\n' "$OUT" | grep -Fxq "== 汇总: write=$EXPECTED_WRITES skip=0 fail=0 =="; then
  ok "L2 汇总 write=$EXPECTED_WRITES skip=0 fail=0"
else
  bad "L2 汇总不符：$(printf '%s\n' "$OUT" | grep '== 汇总' | tail -1 || echo 无汇总行)"
fi
FILES="$(find "$WS" -type f | wc -l | tr -d ' ')"
[ "$FILES" -eq "$EXPECTED_FILES" ] && ok "L2 落点文件数 $FILES" || bad "L2 落点文件数 ${FILES}（期望 ${EXPECTED_FILES}）"
SK="$(find "$WS/.dsh/skills" -mindepth 2 -maxdepth 2 -type f -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
if EXPECTED_SKILLS="$(node -p 'const skills = require(process.argv[1]).contents.skills; if (!Array.isArray(skills)) process.exit(1); skills.length' "$SRC/l2/manifest.json" 2>/dev/null)"; then
  [ "$SK" -eq "$EXPECTED_SKILLS" ] && ok "L2 skills=$SK" || bad "L2 skills=${SK}（期望 ${EXPECTED_SKILLS}）"
else
  bad "L2 manifest 无法读取 contents.skills"
fi
if DIFF="$(diff -qr "$L2_SKILLS" "$WS/.dsh/skills" 2>&1)"; then
  ok "L2 skills 落点与源目录一致（含附属文件）"
else
  bad "L2 skills 落点与源目录不一致：$DIFF"
fi

# ---------------------------------------------------------------- 3. 平台逐个装
echo "-- 3. L3 平台包（逐个装）"
PLATFORMS="$(bash "$SRC/l3/install.sh" --list | awk 'NR>1 {print $1}')"
PCOUNT="$(printf '%s\n' "$PLATFORMS" | grep -c .)"
[ "$PCOUNT" -eq 7 ] && ok "平台清单 7 个" || bad "平台清单 $PCOUNT 个（期望 7）"
for p in $PLATFORMS; do
  OUT="$(bash "$SRC/l3/install.sh" "$p" "$WS" 2>&1)"; RC=$?
  W="$(printf '%s\n' "$OUT" | sed -n 's/^== 汇总: write=\([0-9]*\) skip=\([0-9]*\) fail=\([0-9]*\) ==/\1 \2 \3/p' | tail -1)"
  LANDED="$(find "$WS/95-engine/platforms/$p" -type f 2>/dev/null | wc -l | tr -d ' ')"
  EXPECTED="$(find "$SRC/l3/platforms/$p" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')"
  if [ "$p" = "amazon" ]; then
    SK="$(find "$WS/95-engine/platforms/$p/skills" -type f -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
    [ "$SK" -eq 23 ] && ok "平台 $p skills=23" || bad "平台 $p skills=${SK}（期望 23）"
  fi
  if [ "$RC" -eq 0 ] && [ "$W" = "$EXPECTED 0 0" ] && [ "$LANDED" -eq "$EXPECTED" ]; then
    ok "平台 $p 安装（write=$EXPECTED skip=0 fail=0，落点 ${EXPECTED}）"
  else
    bad "平台 $p 安装（rc=$RC 汇总='${W:-无}' 落点=${LANDED}）"
  fi
done
DIRS="$(find "$WS/95-engine/platforms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$DIRS" -eq 7 ] && ok "平台落点目录 7 个" || bad "平台落点目录 $DIRS 个（期望 7）"

# ---------------------------------------------------------------- 4. 全量 --check
echo "-- 4. 全量 --check（不写）"
SUM_BEFORE="$(cd "$WS" && find . -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1)"
OUT="$(bash "$SRC/l2/install.sh" "$WS" --check 2>&1)"; RC=$?
LINE="$(printf '%s\n' "$OUT" | grep '^== CHECK' | tail -1)"
if [ "$RC" -eq 0 ] && printf '%s\n' "$LINE" | grep -q 'would-write=0 '; then
  ok "L2 --check 幂等（${LINE}）"
else
  bad "L2 --check（rc=$RC ${LINE:-无 CHECK 行}）"
fi
for p in $PLATFORMS; do
  OUT="$(bash "$SRC/l3/install.sh" "$p" "$WS" --check 2>&1)"; RC=$?
  LINE="$(printf '%s\n' "$OUT" | grep '^== CHECK' | tail -1)"
  if [ "$RC" -eq 0 ] && printf '%s' "$LINE" | grep -q 'would-write=0 '; then
    ok "平台 $p --check 幂等（${LINE}）"
  else
    bad "平台 $p --check（rc=$RC ${LINE:-无 CHECK 行}）"
  fi
done
SUM_AFTER="$(cd "$WS" && find . -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1)"
if [ "$SUM_BEFORE" = "$SUM_AFTER" ]; then
  ok "--check 未改任何文件（shasum 一致 ${SUM_BEFORE:0:12}…）"
else
  bad "--check 改了文件（$SUM_BEFORE -> ${SUM_AFTER}）"
fi

# ---------------------------------------------------------------- 5. 空目录负例
echo "-- 5. 负例：空目录装平台必须 FAIL 且 0 写入"
E="$TMP/empty"
mkdir -p "$E"
OUT="$(bash "$SRC/l3/install.sh" ebay "$E" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "空目录装 ebay 退出码 ${RC}（非 0）" || bad "空目录装 ebay 退出码 0（应 FAIL）"
printf '%s' "$OUT" | grep -q 'FAIL 目标目录未装 L2' \
  && ok "空目录失败原因正确（未装 L2）" \
  || bad "空目录失败原因不符：$(printf '%s\n' "$OUT" | grep FAIL | tail -1 || echo 无 FAIL 行)"
EFILES="$(find "$E" -type f | wc -l | tr -d ' ')"
[ "$EFILES" -eq 0 ] && ok "空目录 0 写入" || bad "空目录写了 $EFILES 个文件"

# ---------------------------------------------------------------- 6. 取页器与平台预设（静态）
echo "-- 6. 取页器与平台预设（静态）"
CONN="$SRC/connectors"
node --check "$CONN/farm-probe.js" 2>/dev/null && ok "node --check farm-probe.js" || bad "语法错 farm-probe.js"
PN=0
for p in amazon ebay tiktokshop shopee lazada walmart aliexpress; do
  [ -f "$CONN/platforms/$p.json" ] && PN=$((PN+1)) || bad "缺平台预设 $p.json"
done
[ "$PN" -eq 7 ] && ok "平台预设 7 个齐全" || bad "平台预设只有 $PN 个（期望 7）"
# schema：逐文件校验；verified 只允许「命中…」或「未验…」开头（不许写 ok/true 之类的假声明）
while IFS=$'\t' read -r pfile verdict reason; do
  [ -n "$pfile" ] || continue
  if [ "$verdict" = "1" ]; then
    ok "预设 $pfile 合规（id/name/search_url_template/list_selector/fields/verified/notes）"
  else
    bad "预设 $pfile 不合规：$reason"
  fi
done < <(node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
const need = ["id", "name", "search_url_template", "list_selector", "fields", "verified", "notes"];
for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
  let p = null;
  try { p = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")); } catch (e) { console.log(f + "\t0\t不是合法 JSON"); continue; }
  const miss = [];
  for (const k of need) if (p[k] === undefined || p[k] === null || String(p[k]).trim() === "") miss.push("缺 " + k);
  if (p.fields && (typeof p.fields !== "object" || !Object.keys(p.fields).length)) miss.push("fields 为空");
  if (p.verified && (typeof p.verified !== "object" || !Object.keys(p.verified).length)) miss.push("verified 为空");
  if (p.verified && typeof p.verified === "object") {
    for (const [k, v] of Object.entries(p.verified)) {
      const s = String(v);
      if (!(s.startsWith("命中") || s.startsWith("未验"))) miss.push("verified." + k + " 不是 命中/未验 开头");
    }
  }
  if (p.notes !== undefined && (!Array.isArray(p.notes) || !p.notes.length)) miss.push("notes 为空");
  if (p.id && String(p.id) !== path.basename(f, ".json")) miss.push("id 与文件名不一致");
  console.log(f + "\t" + (miss.length ? "0" : "1") + "\t" + miss.join("；"));
}' "$CONN/platforms")
# L3：每个平台都必须声明 browser-farm 连接器，且 probe_preset 指向真实存在的预设文件
while IFS=$'\t' read -r pname verdict detail; do
  [ -n "$pname" ] || continue
  if [ "$verdict" = "1" ]; then
    ok "L3 $pname 接上取数预设（browser-farm.probe_preset=${detail}）"
  else
    bad "L3 $pname 取数预设未接上：$detail"
  fi
done < <(node -e '
const fs = require("fs"), path = require("path");
const root = process.argv[1];
for (const p of fs.readdirSync(path.join(root, "l3/platforms")).sort()) {
  let mf = null;
  try { mf = JSON.parse(fs.readFileSync(path.join(root, "l3/platforms", p, "manifest.json"), "utf8")); }
  catch (e) { console.log(p + "\t0\tmanifest 不可解析"); continue; }
  const c = (mf.connectors || []).find((x) => x.id === "browser-farm");
  if (!c) { console.log(p + "\t0\tconnectors 里没有 browser-farm"); continue; }
  const pp = c.probe_preset;
  if (typeof pp !== "string" || !pp.trim()) { console.log(p + "\t0\tbrowser-farm 缺 probe_preset"); continue; }
  if (!fs.existsSync(path.join(root, "connectors/platforms", pp + ".json"))) {
    console.log(p + "\t0\tprobe_preset=" + pp + " 没有对应预设文件"); continue;
  }
  console.log(p + "\t1\t" + pp);
}' "$SRC")

# ---------------------------------------------------------------- 7. 边界
if [ -n "$REAL_MTIME" ]; then
  NOW="$(stat -f %m "$REAL_WS" 2>/dev/null || stat -c %Y "$REAL_WS" 2>/dev/null || true)"
  if [ "$NOW" = "$REAL_MTIME" ]; then
    ok "真工作区未被写（mtime 未变）"
  else
    bad "真工作区 mtime 变了（$REAL_MTIME -> ${NOW}）"
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
