#!/usr/bin/env bash
# =============================================================================
# verify.sh — kualang 三层总装验收（一条命令）
#
# 用法：
#   bash verify.sh            # 跑完清掉临时目录
#   bash verify.sh --keep     # 保留临时目录，便于事后看现场
#
# 流程：临时目录里依次 L2 → 7 个平台 → 全量 --check → 空目录、农场版本闸与 requires 负例，
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

TMP="$(mktemp -d /tmp/kualang-verify.XXXXXX)" || { echo "FAIL 无法创建临时目录"; exit 2; }
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

echo "== kualang 三层总装验收 =="
echo "仓库：$ROOT"
echo "临时根目录：$TMP"

# ---------------------------------------------------------------- 0. 入口文件
echo "-- 0. 入口文件"
for f in "l1/install.sh" "l1/manifest.json" "l1/capability/browser-farm.json" "l2/install.sh" "l2/manifest.json" "l3/install.sh" "l3/manifest.json" "l3/schema/platform.schema.json" "l3/check-bundle-skills.js"; do
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
echo "-- 1. L1 核心包 kualang-l1"
L1T="$TMP/l1"
OUT="$(bash "$SRC/l1/install.sh" "$L1T" 2>&1)"; RC=$?
W="$(printf '%s\n' "$OUT" | sed -n 's/^== 汇总: write=\([0-9]*\) skip=\([0-9]*\) fail=\([0-9]*\) ==/\1 \2 \3/p' | tail -1)"
# L1 只写 .dsh/kualang-l1.json，首次安装恒为 1 次写入。
if [ "$RC" -eq 0 ] && [ "$W" = "1 0 0" ]; then
  ok "L1 install（write=1 skip=0 fail=0）"
else
  bad "L1 install（rc=$RC 汇总='${W:-无}'）"
fi
if printf '%s' "$OUT" | grep -q 'WARN 网关不可达'; then
  warn "L1 网关不可达（安装器只 WARN，未挡安装）"
fi
MARKER="$L1T/.dsh/kualang-l1.json"
if [ -f "$MARKER" ] && node -e '
const m = require(process.argv[1]);
if (m.name !== "kualang-l1" || m.capability !== "browser-farm") process.exit(1);
' "$MARKER" 2>/dev/null; then
  ok "L1 标记文件可解析（name=kualang-l1 capability=browser-farm）"
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
echo "-- 2. L2 版本包 kualang-cbec"
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
# skill 承诺的脚本与话术库必须真的随包装进工作区（曾漏发过）
L2_MISSING=""
for f in scripts/cs_router.py scripts/gen_listing.py scripts/ops_report.py scripts/score_products.py scripts/screen_to_candidates.py scripts/spapi_fetch.py scripts/ebay_fetch.py scripts/fetch_router.py scripts/credentials.py scripts/credential_check.py data/faq.json; do
  [ -s "$WS/$f" ] || L2_MISSING="$L2_MISSING $f"
done
if [ -z "$L2_MISSING" ]; then
  ok "L2 工作区随包脚本 10 个 + faq.json 齐全"
else
  bad "L2 工作区缺随包文件：${L2_MISSING# }"
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
  EXPECTED="$(bash "$SRC/l3/list-platform-files.sh" "$SRC/l3/platforms/$p" | wc -l | tr -d ' ')"
  if [ "$p" = "amazon" ]; then
    SK="$(find "$WS/95-engine/platforms/$p/skills" -type f -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
    [ "$SK" -eq 23 ] && ok "平台 $p skills=23" || bad "平台 $p skills=${SK}（期望 23）"
  fi
  if [ "$RC" -eq 0 ] && [ "$W" = "$EXPECTED 0 0" ] && [ "$LANDED" -eq "$EXPECTED" ]; then
    ok "平台 $p 安装（write=$EXPECTED skip=0 fail=0，落点 ${EXPECTED}）"
  else
    bad "平台 $p 安装（rc=$RC 汇总='${W:-无}' 落点=${LANDED}）"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
  if BUNDLE_OUT="$(node "$SRC/l3/check-bundle-skills.js" "$SRC/l3/platforms/$p" 2>&1)"; then
    if [ -n "$BUNDLE_OUT" ]; then ok "平台 $p ${BUNDLE_OUT#PASS }"; fi
  else
    bad "平台 $p bundle skills 与分层 skills 不一致"
    printf '%s\n' "$BUNDLE_OUT" | sed 's/^/    /'
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

# ---------------------------------------------------------------- 5a. 农场版本闸负例
echo "-- 5a. 负例：农场版本不满足必须 FAIL 且 0 写入"
NEG_L3="$TMP/l3-version-negative"
NEG_TARGET="$TMP/version-negative-target"
if mkdir -p "$NEG_L3/platforms" "$NEG_TARGET" &&
   cp "$SRC/l3/"{install.sh,list-platform-files.sh,check-bundle-skills.js,manifest.json} "$NEG_L3/" &&
   cp -R "$SRC/l3/schema" "$NEG_L3/" &&
   cp -R "$SRC/l3/platforms/ebay" "$NEG_L3/platforms/" &&
   node -e '
const fs = require("fs");
const file = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
manifest.requires["browser-farm"] = ">=99.0.0";
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
' "$NEG_L3/platforms/ebay/manifest.json"; then
  OUT="$(bash "$NEG_L3/install.sh" ebay "$NEG_TARGET" 2>&1)"; RC=$?
  if [ -n "$(find "$NEG_TARGET" -mindepth 1 -print -quit)" ]; then
    bad "L3 农场版本闸负例写入了目标目录"
  elif [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q '^FAIL browser-farm .* < 要求 99\.0\.0$'; then
    printf '%s\n' "$OUT" | grep '^FAIL browser-farm ' | sed 's/^/    /'
    ok "L3 农场版本闸负例（rc=$RC，目标 0 写入）"
  elif [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q '^FAIL 目标目录未装 L2' &&
       printf '%s\n' "$OUT" | grep -q '^WARN .*跳过版本闸$'; then
    warn "L3 农场版本闸负例跳过：$(printf '%s\n' "$OUT" | grep '^WARN .*跳过版本闸$')"
  else
    bad "L3 农场版本闸负例未按预期失败（rc=$RC）"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
else
  bad "无法准备 L3 农场版本闸负例的平台包副本"
fi

# ---------------------------------------------------------------- 5b. requires 错误键名负例
echo "-- 5b. 负例：requires 键名错误必须 FAIL 且 0 写入"
if OUT="$(
  exec 2>&1
  l3="$TMP/l3-requires-negative" target="$TMP/requires-negative-target"
  manifest="$l3/platforms/shopee/manifest.json" backup="$TMP/requires-manifest.bak"
  if ! cp -R "$SRC/l3" "$l3" || ! cp "$manifest" "$backup" || ! mkdir "$target"; then
    echo "无法准备 L3 requires 负例的平台包副本"
    exit 1
  fi
  trap 'cp "$backup" "$manifest" || exit 1' EXIT
  trap 'exit 1' HUP INT TERM

  node -e '
const fs = require("fs");
const file = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
const requires = manifest.requires;
if (!Object.hasOwn(requires, "kualang-cbec") || Object.hasOwn(requires, "dsh-ecom-cbec")) process.exit(1);
requires["dsh-ecom-cbec"] = requires["kualang-cbec"];
delete requires["kualang-cbec"];
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
' "$manifest" || exit 1

  out="$(bash "$l3/install.sh" shopee "$target" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] &&
     printf '%s\n' "$out" | grep -Fxq '  FAIL requires 含未知键 dsh-ecom-cbec' &&
     printf '%s\n' "$out" | grep -Fxq 'FAIL 平台 manifest 未通过 schema 校验' &&
     printf '%s\n' "$out" | grep -Fxq '== 汇总: write=0 skip=0 fail=1 ==' &&
     entries="$(find "$target" -mindepth 1 -print -quit)" && [ -z "$entries" ]; then
    echo "L3 requires 错误键名负例（rc=${rc}，目标 0 写入）"
  else
    printf '%s\n' "$out"
    exit 1
  fi
)"; then
  ok "$OUT"
else
  bad "L3 requires 错误键名负例未按预期失败或还原"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

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

# ---------------------------------------------------------------- 7. SP-API 本地假服务
echo "-- 7. SP-API 本地假服务"
if OUT="$(bash "$CONN/spapi-selftest.sh" 2>&1)" && printf '%s\n' "$OUT" | grep -Fxq 'RESULT: READY'; then
  ok "SP-API 本地假服务自检（catalog / report）"
else
  bad "SP-API 本地假服务自检"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7a. eBay 本地假服务
echo "-- 7a. eBay 本地假服务"
if OUT="$(bash "$CONN/ebay-selftest.sh" 2>&1)" && printf '%s\n' "$OUT" | grep -Fxq 'RESULT: READY'; then
  ok "eBay 本地假服务自检（token / search / 429 重试）"
else
  bad "eBay 本地假服务自检"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7b. 降级链
echo "-- 7b. 降级链"
if OUT="$(PYTHONDONTWRITEBYTECODE=1 bash "$CONN/router-selftest.sh" 2>&1)" && printf '%s\n' "$OUT" | grep -Fxq 'RESULT: READY'; then
  ok "降级链自检（T1 / T3 / E_NO_TIER）"
else
  bad "降级链自检"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7c. AliExpress 离线币种闸门
echo "-- 7c. AliExpress 离线币种闸门"
ALI_SCRIPTS="$WS/.dsh/skills/market-research/scripts"
ALI_FIXTURE="$ALI_SCRIPTS/fixtures/aliexpress_us_trim.html"
if OUT="$(python3 "$ALI_SCRIPTS/fetch_aliexpress.py" search "pet slow feeder" --html "$ALI_FIXTURE")" &&
   printf '%s\n' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d["rows"]
prices = [r["sale_price_usd"] for r in rows]
if not (
    d["currency_verified"] is True and d["lang"] == "en" and d["count"] == len(rows) >= 10
    and None not in prices and prices[:5] == [3.82, 3.91, 3.42, 1.09, 3.43]
    and all(r["original_price_usd"] is None and r["rating"] is None for r in rows)
    and {11, 1000, 10000}.issubset(r["sold_count"] for r in rows)
):
    sys.exit(1)
'; then
  ok "AliExpress 美元样本（≥10 条、分转美元、sold 解析、未验证字段为 null）"
else
  bad "AliExpress 美元样本解析不符"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

ALI_NON_USD="$TMP/aliexpress-non-usd.html"
if python3 -c '
from pathlib import Path
import sys
html = Path(sys.argv[1]).read_text(encoding="utf-8")
Path(sys.argv[2]).write_text(html.replace("US $", "JP¥"), encoding="utf-8")
' "$ALI_FIXTURE" "$ALI_NON_USD"; then
  OUT="$(python3 "$ALI_SCRIPTS/fetch_aliexpress.py" search "pet slow feeder" --html "$ALI_NON_USD")"; RC=$?
  if [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not (
    d["lang"] == "en" and d["currency_verified"] is False
    and d["count"] == 0 and d["rows"] == [] and "usd_price_marker_missing" in d["degraded"]
):
    sys.exit(1)
'; then
    ok "AliExpress 日元样本被拒（非 0 退出，无商品或价格）"
  else
    bad "AliExpress 日元样本未按预期拒绝（rc=$RC）"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
else
  bad "无法准备 AliExpress 日元负例"
fi

# ---------------------------------------------------------------- 7d. 粗筛报告口径
echo "-- 7d. 粗筛报告口径"
SCREEN_SCRIPT="$WS/.dsh/skills/market-research/scripts/screen_keyword.py"
SCREEN_FIXTURE="$(dirname "$SCREEN_SCRIPT")/fixtures/screen"
SCREEN_OUT="$TMP/screen"
SCREEN_NAME="pet slow feeder-粗筛"
if OUT="$(python3 "$SCREEN_SCRIPT" "pet slow feeder" --from-json "$SCREEN_FIXTURE" --out "$SCREEN_OUT" 2>&1)"; then
  ok "粗筛离线运行退出码 0"
else
  bad "粗筛离线运行失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

SCREEN_MISSING_SECTIONS=""
for section in 需求侧 进入难度 货源侧 缺口 数据可信度; do
  grep -Fxq "## $section" "$SCREEN_OUT/$SCREEN_NAME.md" || SCREEN_MISSING_SECTIONS="$SCREEN_MISSING_SECTIONS $section"
done
if [ -z "$SCREEN_MISSING_SECTIONS" ]; then
  ok "粗筛 Markdown 五节齐全"
else
  bad "粗筛 Markdown 缺节：${SCREEN_MISSING_SECTIONS# }"
fi

if OUT="$(python3 - "$SCREEN_OUT/$SCREEN_NAME" 2>&1 <<'PY'
import csv
import sys
from pathlib import Path

base = sys.argv[1]
csv_path = Path(base + ".csv")
with csv_path.open(encoding="utf-8", newline="") as file:
    reader = csv.DictReader(file)
    expected = [
        "搜索结果总数", "广告密度", "评论数中位数", "评论数最大", "评论数>1000占比", "评分中位数", "价格带",
        "上架月龄中位数", "新品占比(<12个月)", "FBA占比", "卖家数",
        "货源价中位数", "货源折扣中位数", "货源销量中位数", "零货倍数",
    ]
    if reader.fieldnames != ["指标", "值", "样本量", "来源", "证据等级", "备注"]:
        sys.exit(f"粗筛 CSV 表头不符：{reader.fieldnames!r}")
    actual = [row["指标"] for row in reader]
    if actual != expected:
        sys.exit(f"粗筛 CSV 指标清单不符：{actual!r}")

for path in (csv_path, Path(base + ".md")):
    content = path.read_text(encoding="utf-8")
    if any(word in content for word in ("上架测试", "小批量观察", "放弃")):
        sys.exit(f"{path.name} 含决策词")
PY
)"; then
  ok "粗筛 CSV 15 项指标齐全，Markdown 和 CSV 无决策词"
else
  bad "粗筛 CSV 或决策词校验失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

SCREEN_MISSING="$TMP/screen-missing-fixture"
SCREEN_NEG_OUT="$TMP/screen-missing-out"
OUT=""
if cp -R "$SCREEN_FIXTURE" "$SCREEN_MISSING" &&
   rm "$SCREEN_MISSING/amazon_products.json" &&
   OUT="$(python3 "$SCREEN_SCRIPT" "pet slow feeder" --from-json "$SCREEN_MISSING" --out "$SCREEN_NEG_OUT" 2>&1)" &&
   OUT="$(python3 - "$SCREEN_OUT/$SCREEN_NAME.csv" "$SCREEN_NEG_OUT/$SCREEN_NAME" 2>&1 <<'PY'
import csv
import sys
from pathlib import Path


def age_row(path):
    with Path(path).open(encoding="utf-8", newline="") as file:
        return next(row for row in csv.DictReader(file) if row["指标"] == "上架月龄中位数")


before = age_row(sys.argv[1])
base = sys.argv[2]
after = age_row(base + ".csv")
md = Path(base + ".md").read_text(encoding="utf-8")
if "缺少 amazon_products.json" in before["备注"]:
    sys.exit(f"完整 fixture 意外触发文件缺失：{before!r}")
if not (
    after["值"] == "NA" and after["证据等级"] == "D"
    and "缺少 amazon_products.json" in after["备注"]
    and "| 上架月龄中位数 | NA（缺少 amazon_products.json" in md
):
    sys.exit(f"缺少商品页时月龄未标为 NA 并附缺失原因：{after!r}")
PY
)"; then
  ok "删掉 amazon_products.json 后，上架月龄中位数为 NA（含缺失原因）"
else
  bad "删掉 amazon_products.json 后，上架月龄中位数校验失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

SCREEN_OK="$TMP/screen-ok-fixture"
SCREEN_OK_OUT="$TMP/screen-ok-out"
OUT=""
if [ ! -e "$SCREEN_FIXTURE/amazon_search_ok.json" ] && [ ! -e "$SCREEN_FIXTURE/amazon_products_ok.json" ]; then
  warn "跳过 Amazon 真实样本需求侧断言（本轮未能取到可用样本，见 docs/amazon-throttle.md）"
elif mkdir -p "$SCREEN_OK" &&
     cp "$SCREEN_FIXTURE/amazon_search_ok.json" "$SCREEN_OK/amazon_search.json" &&
     cp "$SCREEN_FIXTURE/amazon_products_ok.json" "$SCREEN_OK/amazon_products.json" &&
     cp "$SCREEN_FIXTURE/aliexpress_search.json" "$SCREEN_OK/" &&
     OUT="$(python3 "$SCREEN_SCRIPT" "pet slow feeder" --top 10 --from-json "$SCREEN_OK" --out "$SCREEN_OK_OUT" 2>&1)" &&
     OUT="$(python3 - "$SCREEN_OK/amazon_search.json" "$SCREEN_OK_OUT/$SCREEN_NAME.csv" 2>&1 <<'PY'
import csv
import json
import sys
from pathlib import Path

raw = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if raw.get("error") or len(raw.get("rows", [])) != 10:
    sys.exit("Amazon ok 搜索样本需要包含 10 条商品卡片")
with Path(sys.argv[2]).open(encoding="utf-8", newline="") as file:
    metrics = {row["指标"]: row for row in csv.DictReader(file)}
for name in ("搜索结果总数", "广告密度", "评论数中位数", "评论数最大", "评论数>1000占比", "评分中位数", "价格带"):
    row = metrics.get(name, {})
    if row.get("证据等级") != "B" or row.get("值") in (None, "", "NA"):
        sys.exit(f"Amazon 真实样本需求侧指标异常：{name} {row!r}")
PY
)"; then
  ok "Amazon 真实样本需求侧指标均为 B 且有值"
else
  bad "Amazon 真实样本需求侧校验失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7e. 粗筛离线重放与估算闸门
echo "-- 7e. 粗筛离线重放与估算闸门"
SCREEN_CAPTURE="$TMP/screen-capture"
SCREEN_REPLAY="$TMP/screen-replay"
if OUT="$(python3 -B - "$SCREEN_SCRIPT" "$SCREEN_FIXTURE" "$SCREEN_CAPTURE" 2>&1 <<'PY'
import json
import sys
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

script, fixture, out = map(Path, sys.argv[1:])
sys.path.insert(0, str(script.parent))
import screen_keyword

keyword = "pet slow feeder"
product_sequence = json.loads((fixture / "amazon_products_503.json").read_text(encoding="utf-8"))["rows"]
products = {row["asin"]: row for row in product_sequence}
amazon = {"keyword": keyword, "rows": [{"asin": asin} for asin in products]}
ali = json.loads((fixture / "aliexpress_search.json").read_text(encoding="utf-8"))
calls = []
waits = []


def fetch(command, **kwargs):
    fetcher = Path(command[1]).name
    if fetcher == "fetch_aliexpress.py":
        payload = ali
    elif fetcher == "fetch_amazon.py" and command[2] == "product":
        asin = command[3]
        if command[4:] != ["--min-interval", "5"]:
            sys.exit(f"商品页重试未沿用默认采集间隔：{command[4:]!r}")
        calls.append(asin)
        payload = products[asin]
    elif fetcher == "fetch_amazon.py":
        payload = amazon
    else:
        sys.exit(f"意外调用抓取器：{fetcher}")
    return CompletedProcess(command, 0, stdout=json.dumps(payload), stderr="")


argv = [str(script), keyword, "--top", str(len(products)), "--out", str(out)]
with patch.object(sys, "argv", argv), patch.object(screen_keyword.subprocess, "run", side_effect=fetch):
    with patch.object(screen_keyword.time, "sleep", side_effect=waits.append):
        with patch.object(screen_keyword, "now", return_value="2026-02-01T12:00:00+08:00"):
            screen_keyword.main()
(out / "calls.json").write_text(json.dumps({"asins": calls, "waits": waits}), encoding="utf-8")
PY
)" &&
   [ -s "$SCREEN_CAPTURE/raw/amazon_search.json" ] &&
   [ -s "$SCREEN_CAPTURE/raw/amazon_products.json" ] &&
   [ -s "$SCREEN_CAPTURE/raw/aliexpress_search.json" ] &&
   OUT="$(python3 "$SCREEN_SCRIPT" "pet slow feeder" --top 6 --from-json "$SCREEN_CAPTURE/raw" --out "$SCREEN_REPLAY" 2>&1)" &&
   cmp -s "$SCREEN_CAPTURE/$SCREEN_NAME.csv" "$SCREEN_REPLAY/$SCREEN_NAME.csv"; then
  ok "粗筛在线路径落盘三份 raw，离线重放 CSV 逐字一致"
else
  bad "粗筛 raw 落盘或离线重放 CSV 不一致"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

if OUT="$(python3 - "$SCREEN_FIXTURE" "$SCREEN_CAPTURE" "$SCREEN_REPLAY/$SCREEN_NAME" 2>&1 <<'PY'
import csv
import json
import sys
from pathlib import Path

fixture, capture, replay = map(Path, sys.argv[1:])
sequence = json.loads((fixture / "amazon_products_503.json").read_text(encoding="utf-8"))["rows"]
calls = json.loads((capture / "calls.json").read_text(encoding="utf-8"))
raw = json.loads((capture / "raw/amazon_products.json").read_text(encoding="utf-8"))
expected_asins = [row["asin"] for row in sequence[:-1]]
if (calls != {"asins": expected_asins, "waits": [2] + [5] * len(expected_asins)}
    or [row["asin"] for row in raw["rows"]] != expected_asins or raw.get("skipped_after_503") != 1):
    sys.exit(f"商品页停止点或间隔不符：{calls!r} {raw!r}")
for md in (capture / replay.with_suffix(".md").name, replay.with_suffix(".md")):
    if "提前停止：剩余 1 个商品页未抓，原因 503" not in md.read_text(encoding="utf-8"):
        sys.exit(f"{md} 缺少提前停止原因")
with replay.with_suffix(".csv").open(encoding="utf-8", newline="") as file:
    metrics = {row["指标"]: row for row in csv.DictReader(file)}
fba = metrics["FBA占比"]
if (fba["值"], fba["样本量"], fba["备注"]) != ("0.2", "5", "fba=1，fbm=1，unknown=3"):
    sys.exit(f"FBA 占比分母不符：{fba!r}")
if metrics["上架月龄中位数"]["样本量"] != "2/5" or metrics["卖家数"]["样本量"] != "2/5":
    sys.exit(f"进入难度统计含未抓样本：{metrics!r}")
PY
)"; then
  ok "连续 503 提前停止，在线及重放报告标记剩余页数，未抓页不计入统计"
else
  bad "连续 503 提前停止或进入难度统计校验失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

ESTIMATE_SCRIPT="$(dirname "$SCREEN_SCRIPT")/estimate_columns.py"
ESTIMATE_OUT="$TMP/estimate.csv"
ESTIMATE_SCORE="$TMP/estimate-score.csv"
if OUT="$(python3 - "$WS/data/candidates.sample.csv" 2>&1 <<'PY'
import csv
import sys
with open(sys.argv[1], encoding="utf-8-sig", newline="") as file:
    print(next(csv.DictReader(file))["预估售价"])
PY
)" &&
   OUT="$(python3 "$ESTIMATE_SCRIPT" --from-json "$SCREEN_FIXTURE" --out "$ESTIMATE_OUT" \
                  --as-score-input "$ESTIMATE_SCORE" --score-price "$OUT" 2>&1)" &&
   OUT="$(python3 "$ESTIMATE_SCRIPT" "$SCREEN_OUT/$SCREEN_NAME.csv" --out "$TMP/estimate-from-csv.csv" 2>&1)" &&
   cmp -s "$ESTIMATE_OUT" "$TMP/estimate-from-csv.csv" &&
   OUT="$(python3 - "$ESTIMATE_OUT" 2>&1 <<'PY'
import csv
import sys
with open(sys.argv[1], encoding="utf-8", newline="") as file:
    reader = csv.DictReader(file)
    if reader.fieldnames != ["指标", "估算值", "公式", "证据等级", "不确定性", "备注"]:
        sys.exit(f"估算表头不符：{reader.fieldnames!r}")
    records = list(reader)
    if len(records) != 5:
        sys.exit(f"估算行数不符：{len(records)}")
rows = {row["指标"]: row for row in records}
expected = {"估算_在售竞品数", "估算_1688进价", "估算_月搜索量", "估算_平均退货率", "估算_运费"}
if set(rows) != expected or any(
    not all((value or "").strip() for value in row.values()) or "输入指标" not in row["备注"]
    for row in rows.values()
):
    sys.exit(f"估算指标或行内证据不完整：{rows!r}")
for name, row in rows.items():
    if name == "估算_1688进价":
        if row["证据等级"] != "C" or not float(row["估算值"]) > 0 or "上界" not in row["公式"]:
            sys.exit(f"货源价上界参考不符：{row!r}")
    elif (row["估算值"], row["证据等级"]) != ("NA", "D"):
        sys.exit(f"缺少来源的指标应为 NA、D：{row!r}")
PY
)"; then
  ok "粗筛 CSV 与 JSON 估算一致，五项均有公式、输入指标、证据等级和不确定性"
else
  bad "估算表内容或 CSV 与 JSON 一致性校验失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

if cp "$ESTIMATE_SCORE" "$WS/data/candidates.csv" &&
   OUT="$(python3 "$WS/scripts/score_products.py" 2>&1)" &&
   printf '%s\n' "$OUT" | grep -Fq "补数据" &&
   ! printf '%s\n' "$OUT" | grep -Fq "上架测试" &&
   OUT="$(python3 - "$ESTIMATE_SCORE" "$WS/out/选品打分.csv" 2>&1 <<'PY'
import csv
import sys

missing = {"在售竞品数", "1688进价", "月搜索量", "平均退货率", "运费"}
with open(sys.argv[1], encoding="utf-8", newline="") as file:
    fields = csv.DictReader(file).fieldnames
    if missing.intersection(fields) or not {f"估算_{name}" for name in missing}.issubset(fields):
        sys.exit(f"估算打分输入表头未保留前缀：{fields!r}")
with open(sys.argv[2], encoding="utf-8-sig", newline="") as file:
    rows = list(csv.DictReader(file))
if not rows or any((row["决策"], row["证据等级"], row["可算维度"]) != ("补数据", "D", "0/4") for row in rows):
    sys.exit(f"打分未保留补数据：{rows!r}")
for row in rows:
    if not all(name in row["缺口"] for name in missing):
        sys.exit(f"估算值被打分脚本采信：{row!r}")
PY
)"; then
  ok "估算列保留估算_前缀，选品打分仍为补数据"
else
  bad "估算打分安全闸校验失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7f. 证据分层打分
echo "-- 7f. 证据分层打分"
if OUT="$(python3 -B - "$WS/scripts" 2>&1 <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from score_products import build


def check(label, rows, passed):
    outcome = f"PASS {label}" if passed else f"FAIL {label}；实际：{rows!r}"
    print(outcome)


def result_for(candidate, *other_candidates):
    return next(row for row in build([candidate, *other_candidates]) if row["商品名"] == candidate["商品名"])


empty = {"商品名": "全缺样例", "预估售价": "20"}
strong = {
    "商品名": "四维厚利", "预估售价": "100", "1688进价": "5", "运费": "5", "平均退货率": "0",
    "月搜索量": "100000", "在售竞品数": "1", "头部评论数": "1", "供应稳定性分": "10",
}
weak = {
    "商品名": "对照组", "预估售价": "30", "1688进价": "25", "运费": "10", "平均退货率": "0.05",
    "月搜索量": "100", "在售竞品数": "1000", "头部评论数": "8000", "供应稳定性分": "3",
}
proxy = {"搜索结果总数": "10000", "广告密度": "1"}

row = result_for(empty)
check("7f.1 全缺样例为 D、0/4、补数据，分数和利润留空", row,
      (row["决策"], row["证据等级"], row["可算维度"]) == ("补数据", "D", "0/4")
      and not row.get("总分") and not row.get("贡献利润"))

two = dict(empty, **proxy, 评论数中位数="5", 评分中位数="3", **{"评论数>1000占比": "0"})
row = result_for(two)
proxy_full = dict(strong, **proxy, 商品名="四维代理")
del proxy_full["月搜索量"]
full = result_for(proxy_full, weak)
check("7f.2 需求与竞争两维最多观察，四维含需求代理仍不能上架", (row, full),
      row["可算维度"] == "2/4" and row["证据等级"] == "C" and row["决策"] in ("小批量观察", "放弃")
      and full["可算维度"] == "4/4" and full["证据等级"] == "C" and float(full["总分"]) >= 60
      and not full["红线"] and full["决策"] == "小批量观察")

row = result_for(strong, weak)
secondary = dict(strong, 商品名="四维含二级", 上架月龄中位数="0", FBA占比="0")
del secondary["供应稳定性分"]
full = result_for(secondary, weak)
check("7f.3 四维齐、贡献利润厚且无红线时可上架测试", (row, full),
      (row["决策"], row["证据等级"], row["可算维度"], row["红线"]) == ("上架测试", "A", "4/4", "")
      and (full["决策"], full["证据等级"], full["可算维度"], full["红线"]) == ("上架测试", "B", "4/4", "")
      and row["贡献利润率"] == "70.0%" and "推广费率=0.15" in row["诊断"])

no_profit = dict(strong, 商品名="利润未验，其他三维满分")
del no_profit["1688进价"]
row = result_for(no_profit, weak)
check("7f.4 利润缺失、其他三维满分时仍只观察，诊断与红线标记利润未验", row,
      (row["决策"], row["证据等级"], row["可算维度"], row["总分"]) == ("小批量观察", "B", "3/4", "100.0")
      and not row.get("贡献利润") and "利润未验" in row["诊断"] and row["红线"] == "利润未验"
      and "1688进价" in row["缺口"])

estimates = dict(empty, **{f"估算_{key}": value for key, value in dict(strong, **proxy).items()})
row = result_for(estimates)
check("7f.5 估算_ 列不计入任何维度，结论仍为补数据", row,
      row == result_for(empty) and (row["决策"], row["证据等级"], row["可算维度"]) == ("补数据", "D", "0/4"))
PY
)"; then
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok "${line#PASS }" ;;
      "FAIL "*) bad "${line#FAIL }" ;;
      *) bad "证据分层断言输出异常：$line" ;;
    esac
  done <<< "$OUT"
else
  bad "证据分层打分断言执行失败"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7g. 凭证接入层
echo "-- 7g. 凭证接入层"
if OUT="$(python3 -B - "$WS/scripts" "$CONN" "$TMP" 2>&1 <<'PY'
import base64
import io
import json
import os
import subprocess
import sys
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from threading import Thread
from unittest.mock import patch
from urllib.parse import parse_qs

scripts, connectors, temporary = sys.argv[1:]
sys.path[:0] = [scripts, connectors]
import credential_check
import ebay_fetch
import ebay_mock
import spapi_fetch
import spapi_mock


bare = {
    "SP_API_CLIENT_ID": "mock-id", "SP_API_CLIENT_SECRET": "mock-secret",
    "SP_API_REFRESH_TOKEN": "mock-refresh", "EBAY_CLIENT_ID": "mock-id",
    "EBAY_CLIENT_SECRET": "mock-secret",
}
prefixed = {"DSH_SECRET_" + name: value for name, value in bare.items()}
wrong_bare = {name: f"unused-fixture-{index}" for index, name in enumerate(bare)}
clean_env = {name: value for name, value in os.environ.items()
             if name not in bare and not name.startswith("DSH_SECRET_")}
expected_lwa = {"grant_type": ["refresh_token"], "client_id": [bare["SP_API_CLIENT_ID"]],
                "client_secret": [bare["SP_API_CLIENT_SECRET"]],
                "refresh_token": [bare["SP_API_REFRESH_TOKEN"]]}


class StrictLwaHandler(spapi_mock.Handler):
    def do_POST(self):
        self.server.stats["lwa_requests"] += 1
        size = int(self.headers.get("Content-Length", "0"))
        form = parse_qs(self.rfile.read(size).decode("ascii"))
        if (self.path == "/auth/o2/token" and form == expected_lwa
                and self.headers.get_content_type() == "application/x-www-form-urlencoded"):
            self.send_json(200, {"access_token": spapi_mock.ACCESS, "expires_in": 3600})
        else:
            self.send_json(401, {"error": "Invalid mock credentials"})


@contextmanager
def serving(server):
    with server:
        worker = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        worker.start()
        try:
            yield
        finally:
            server.shutdown()
            worker.join()


def token_counts():
    return spapi.stats["lwa_requests"], ebay.stats["token_requests"]


def fetchers_accept(variables):
    before_spapi, before_ebay = token_counts()
    for name, base, arguments, count in (
        ("spapi_fetch.py", spapi.base_url, ["catalog", "--asin", "B0MOCK0001"], 1),
        ("ebay_fetch.py", ebay_url, ["search", "--q", "earbuds", "--limit", "2"], 2),
    ):
        result = subprocess.run(
            [sys.executable, "-B", str(Path(scripts) / name), *arguments,
             "--base-url", base, "--out", temporary],
            env={**clean_env, **variables}, capture_output=True, encoding="utf-8", timeout=10,
        )
        if result.returncode != 0 or result.stderr or json.loads(result.stdout)["items"] != count:
            return False
    return token_counts() == (before_spapi + 1, before_ebay + 1)


def run_checker(variables, *args):
    stdout, stderr = io.StringIO(), io.StringIO()
    with patch.dict(os.environ, {**clean_env, **variables}, clear=True), \
         patch.object(sys, "argv", ["credential_check.py", *args]), \
         patch.object(spapi_fetch, "LWA_URL", spapi.base_url + "/auth/o2/token"), \
         patch.dict(ebay_fetch.ORIGINS, {"sandbox": ebay_url, "production": ebay_url}), \
         redirect_stdout(stdout), redirect_stderr(stderr):
        code = credential_check.main()
    return code, stdout.getvalue(), stderr.getvalue()


def grep_for_credentials(output):
    patterns = {*bare.values(), *wrong_bare.values(), spapi_mock.ACCESS,
                base64.b64encode(b"mock-id:mock-secret").decode("ascii")}
    return subprocess.run(
        ["bash", "-c", 'grep -F -c -f <(printf "%s\\n" "$MOCK_PATTERNS")'],
        input=output, env={**clean_env, "MOCK_PATTERNS": "\n".join(sorted(patterns))},
        capture_output=True, encoding="utf-8", timeout=5,
    )


def checker_redacts():
    before_spapi, before_ebay = token_counts()
    code, stdout, stderr = run_checker({**wrong_bare, **prefixed}, "--json", "--env", "production")
    text_code, text_out, text_err = run_checker(bare)
    failed, rejected_out, rejected_err = run_checker(wrong_bare)
    with patch("socket.create_connection", side_effect=OSError(bare["SP_API_CLIENT_SECRET"])):
        offline, offline_out, offline_err = run_checker(bare)
    grep = grep_for_credentials("\n".join((stdout, stderr, text_out, text_err,
                                           rejected_out, rejected_err, offline_out, offline_err)))
    rows = json.loads(stdout)["credentials"]
    return (code == text_code == 0 and not (stderr or text_err or rejected_err or offline_err)
            and all(row["configured"] is True for row in rows)
            and [(row["name"], row["source"], row["connectivity"]) for row in rows]
            == [(name, "DSH_SECRET_", "reachable") for name in bare]
            and text_out.splitlines() == [f"{name} | 已配置 | 裸名 | 可达" for name in bare]
            and failed == offline == 2 and rejected_out == offline_out
            and rejected_out.splitlines() == [f"{name} | 已配置 | 裸名 | 不可达" for name in bare]
            and token_counts() == (before_spapi + 3, before_ebay + 3)
            and grep.returncode == 1 and grep.stdout.strip() == "0")


def checker_reports_missing():
    before = token_counts()
    code, stdout, stderr = run_checker({}, "--json")
    rows = json.loads(stdout)["credentials"]
    return (code == 2 and not stderr and token_counts() == before
            and [row["name"] for row in rows] == list(bare)
            and all(row["configured"] is False and row["source"] is None
                    and row["connectivity"] == "unconfigured" for row in rows))


def check(label, test, *args):
    try:
        passed = test(*args)
    except Exception:
        passed = False
    print(f"{'PASS' if passed else 'FAIL'} {label}")


spapi = spapi_mock.MockServer()
spapi.RequestHandlerClass = StrictLwaHandler
with serving(spapi), serving(ebay := ebay_mock.MockServer()):
    ebay_url = f"http://127.0.0.1:{ebay.server_port}"
    check("7g.1 只设 DSH_SECRET_ 前缀，SP-API 和 eBay 通过本地 mock", fetchers_accept, prefixed)
    check("7g.2 只设裸名，SP-API 和 eBay 通过本地 mock", fetchers_accept, bare)
    check("7g.3 两种形态同时存在且值不同，两平台均使用前缀值",
          fetchers_accept, {**wrong_bare, **prefixed})
    check("7g.4 自检成功、拒绝和网络失败的输出均无凭证原文（grep -c 为 0）", checker_redacts)
    check("7g.5 全缺凭证时自检退出码为 2，JSON 的 configured 均为 false", checker_reports_missing)
PY
)"; then
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) ok "${line#PASS }" ;;
      "FAIL "*) bad "${line#FAIL }" ;;
      *) bad "凭证接入层断言输出异常" ;;
    esac
  done <<< "$OUT"
else
  bad "凭证接入层断言执行失败"
fi

# ---------------------------------------------------------------- 7h. 发布包
echo "-- 7h. 发布包"
# 外层 release.sh 已核验当前 ZIP，内层只跑安装相关断言。
if [ "${KUALANG_RELEASE_CHECK:-}" = "$ROOT" ]; then
  echo '  INFO 当前处于发行包试装，跳过嵌套发布包核验'
else
  RELEASE_GIT="$TMP/release"
  RELEASE_OUT="$RELEASE_GIT/distribution/out"
  RELEASE_BASELINE=1
  if [ -e "$ROOT/.git" ]; then
    # 只应用根 .gitignore，避免 distribution/.gitignore 掩盖根规则缺失。
    if mkdir -p "$RELEASE_GIT" &&
       git -C "$RELEASE_GIT" init -q --template= &&
       RELEASE_STATUS="$(git -C "$RELEASE_GIT" -c "core.excludesFile=$ROOT/.gitignore" status --porcelain --untracked-files=all)" &&
       [ -z "$RELEASE_STATUS" ]; then
      RELEASE_BASELINE=0
    fi
  fi

  RELEASE_TOP="kualang-$(cat "$ROOT/VERSION")"
  RELEASE_ZIP="$RELEASE_OUT/$RELEASE_TOP.zip"
  RELEASE_UNPACKED="$TMP/release-zip"
  if OUT="$(bash "$SRC/make-bundle.sh" --out "$RELEASE_OUT" 2>&1)" &&
     OUT="$(bash "$SRC/release.sh" --out "$RELEASE_OUT" --check 2>&1)"; then
    ok "7h.1 release.sh --check 退出码 0（临时输出目录）"
  else
    bad "7h.1 构建或 release.sh --check 失败"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi

  if [ -f "$RELEASE_ZIP" ] &&
     unzip -q "$RELEASE_ZIP" -d "$RELEASE_UNPACKED" &&
     [ -s "$RELEASE_UNPACKED/$RELEASE_TOP/docs/credentials-setup.md" ]; then
    ok "7h.2 产物包含 docs/credentials-setup.md"
  else
    bad "7h.2 产物缺少 docs/credentials-setup.md 或无法解包"
  fi

  if (source "$SRC/release.sh" && release_tool payload "$RELEASE_UNPACKED/$RELEASE_TOP"); then
    ok "7h.3 产物无真实凭证、私钥、farm/state、farm/profiles、.env 或 distribution/out"
  else
    bad "7h.3 产物载荷安全检查失败"
  fi

  if [ ! -e "$ROOT/.git" ]; then
    echo '  INFO 解包目录跳过 Git 状态检查'
  elif [ "$RELEASE_BASELINE" -eq 0 ] && [ -f "$RELEASE_ZIP" ] &&
       RELEASE_STATUS="$(git -C "$RELEASE_GIT" -c "core.excludesFile=$ROOT/.gitignore" status --porcelain --untracked-files=all)" &&
       [ -z "$RELEASE_STATUS" ]; then
    ok "7h.4 构建后 git status --porcelain 仍为空（根 .gitignore 忽略 distribution/out/）"
  else
    bad "7h.4 构建后 Git 状态检查失败，请检查根 .gitignore 的 distribution/out/ 规则"
  fi
fi

# ---------------------------------------------------------------- 8. 授权与安装包自检
echo "-- 8. 授权与安装包自检"
for selftest in licence-selftest installer-selftest; do
  if [ "$selftest" = installer-selftest ] && [ "${KUALANG_RELEASE_CHECK:-}" = "$ROOT" ]; then
    echo '  INFO 当前处于发行包试装，跳过会重新打包的 installer-selftest.sh'
    continue
  fi
  if OUT="$(bash "$SRC/$selftest.sh" 2>&1)" && printf '%s\n' "$OUT" | grep -Fxq 'RESULT: READY'; then
    ok "${selftest}.sh"
  else
    bad "${selftest}.sh"
    printf '%s\n' "$OUT" | sed 's/^/    /'
  fi
done

# ---------------------------------------------------------------- 9. 边界
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
