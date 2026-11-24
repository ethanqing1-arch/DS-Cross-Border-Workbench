#!/usr/bin/env bash
# =============================================================================
# install.sh — kualang-platform-framework（L3 平台子模式框架）安装器
#
# 用法：
#   bash install.sh --list                            # 列出可用平台包
#   bash install.sh <platform> <目标目录>              # 非破坏安装：已存在默认跳过
#   bash install.sh <platform> <目标目录> --check      # 只校验，不写任何文件
#   bash install.sh <platform> <目标目录> --force      # 覆盖已存在的同名文件
#
# 前置（目标目录已装 L2，双证）：
#   <目标目录>/CHIEF-INIT.md
#   <目标目录>/.dsh/skills/ecom-selection/SKILL.md
# 环境变量：GATEWAY_URL 默认 http://127.0.0.1:19671，GATEWAY_TOKEN 可选。
#
# 落点：<目标目录>/95-engine/platforms/<platform>/
#
# 边界：只写 <目标目录>；不碰 ~/ds-bot-workspace、不碰 DS Bot 状态、不安装 bundle。
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; }

PLATFORM=""; TARGET=""; CHECK=0; FORCE=0; LIST=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    --list) LIST=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知参数：${arg}（可用 --list / --check / --force）" >&2; exit 2 ;;
    *) if [ -z "$PLATFORM" ]; then PLATFORM="$arg"; else TARGET="$arg"; fi ;;
  esac
done

if [ "$LIST" -eq 1 ]; then
  echo "可用平台包："
  for d in "$SRC"/platforms/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    tier="$(sed -n 's/.*"tier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/manifest.json" | head -1)"
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/manifest.json" | head -1)"
    printf '  %-11s %-9s %s\n' "$id" "$tier" "$name"
  done
  exit 0
fi

[ -n "$PLATFORM" ] && [ -n "$TARGET" ] || { usage; exit 2; }
case "$PLATFORM" in
  *[!a-z0-9-]*) echo "FAIL 平台 id 非法：${PLATFORM}（只允许小写字母/数字/连字符）" >&2; exit 2 ;;
esac
PLATFORM_DIR="$SRC/platforms/$PLATFORM"
if [ ! -d "$PLATFORM_DIR" ]; then
  echo "FAIL 平台包不存在：platforms/$PLATFORM" >&2
  echo "可用：$(cd "$SRC/platforms" && ls -d */ 2>/dev/null | sed 's|/||' | tr '\n' ' ')" >&2
  exit 2
fi

FAILED=0; WROTE=0; SKIPPED=0

echo "== kualang-platform-framework $(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/manifest.json" | head -1) / 平台包 $PLATFORM =="
echo "目标：$TARGET"
echo "模式：$([ "$CHECK" -eq 1 ] && echo '只校验（--check）' || { [ "$FORCE" -eq 1 ] && echo '安装（--force）' || echo '安装（非破坏）'; })"

# ---------------------------------------------------------------- 1. 平台 manifest 校验
echo "-- 1. 平台 manifest schema 校验"
[ -f "$SRC/schema/platform.schema.json" ] || { echo "FAIL 缺 schema/platform.schema.json"; exit 2; }
if PLATFORM_DIR="$PLATFORM_DIR" SCHEMA="$SRC/schema/platform.schema.json" PLATFORM_ID="$PLATFORM" node -e '
const fs = require("fs");
const dir = process.env.PLATFORM_DIR;
const schema = JSON.parse(fs.readFileSync(process.env.SCHEMA, "utf8"));
const pid = process.env.PLATFORM_ID;
let mf;
try { mf = JSON.parse(fs.readFileSync(dir + "/manifest.json", "utf8")); }
catch (e) { console.log("  FAIL manifest 不可解析：" + e.message); process.exit(1); }
const errs = [];
for (const k of (schema.required || [])) if (!(k in mf)) errs.push("缺字段 " + k);
if (mf.id !== pid) errs.push("id=" + mf.id + " 与目录名 " + pid + " 不一致");
const tierEnum = ((schema.properties.tier || {}).enum) || [];
if (tierEnum.indexOf(mf.tier) < 0) errs.push("tier=" + mf.tier + " 不在 " + tierEnum.join("/"));
if (typeof mf.version === "string" && !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(mf.version)) errs.push("version 不是 x.y.z：" + mf.version);
const requiresSchema = schema.properties.requires;
const requires = mf.requires;
if (typeof requires !== requiresSchema.type || requires === null || Array.isArray(requires)) {
  errs.push("requires 必须是对象");
} else {
  for (const key of requiresSchema.required) {
    if (!Object.hasOwn(requires, key)) errs.push("requires 缺键 " + key);
  }
  for (const [key, value] of Object.entries(requires)) {
    if (!Object.hasOwn(requiresSchema.properties, key)) {
      if (requiresSchema.additionalProperties === false) errs.push("requires 含未知键 " + key);
      continue;
    }
    const rule = requiresSchema.properties[key];
    if (typeof value !== rule.type || !new RegExp(rule.pattern).test(value)) {
      errs.push("requires." + key + " 不符合 schema 的类型或格式约束");
    }
  }
}
if (mf.skills) {
  const modes = (((schema.properties.skills || {}).properties || {}).mode || {}).enum || [];
  if (modes.indexOf(mf.skills.mode) < 0) errs.push("skills.mode=" + mf.skills.mode + " 不在 " + modes.join("/"));
}
if (mf.overrides && typeof mf.overrides.path !== "string") errs.push("overrides.path 缺失");
if (errs.length) {
  for (const e of errs) console.log("  FAIL " + e);
  console.log("FAIL 平台 manifest 未通过 schema 校验");
  process.exit(1);
}
const ovPath = dir + "/" + mf.overrides.path;
let ov;
try { ov = JSON.parse(fs.readFileSync(ovPath, "utf8")); }
catch (e) { console.log("FAIL overrides 文件不可解析：" + mf.overrides.path + "（" + e.message + "）"); process.exit(1); }
const values = ov.values || {};
const nulls = Object.keys(values).filter(function (k) { return values[k] && values[k].value === null; });
const noNote = nulls.filter(function (k) { return !values[k]._note; });
if (noNote.length) console.log("  WARN 这些 null 字段没有 _note：" + noNote.join(", "));
console.log("PASS 平台 manifest 通过 schema 校验（id=" + mf.id + " tier=" + mf.tier + " skills.mode=" + mf.skills.mode + "）");
console.log("PASS overrides 可解析（" + mf.overrides.path + "，null 待业务确认 " + nulls.length + " 个字段）");
if (mf.skills.mode === "referenced") console.log("WARN skill 为引用声明（count=" + mf.skills.count + "），包内不含内容");
process.exit(0);
'; then
  :
else
  FAILED=$((FAILED+1))
  echo
  echo "== 汇总: write=$WROTE skip=$SKIPPED fail=$FAILED =="
  echo "INSTALL FAILED（平台 manifest 不合法，未写任何文件）"
  exit 1
fi

# ---------------------------------------------------------------- 农场版本闸
ver_ge() { # $1 >= $2 ?
  local IFS=.
  local -a a b
  a=($1); b=($2)
  local i ai bi
  for i in 0 1 2; do
    ai="${a[$i]:-0}"; bi="${b[$i]:-0}"
    ai="${ai//[!0-9]/}"; bi="${bi//[!0-9]/}"
    [ -n "$ai" ] || ai=0; [ -n "$bi" ] || bi=0
    [ "$ai" -gt "$bi" ] && return 0
    [ "$ai" -lt "$bi" ] && return 1
  done
  return 0
}

echo "-- 农场版本闸"
if ! REQUIRED_FARM="$(node -e '
const requires = require(process.argv[1]).requires;
const version = requires["browser-farm"];
if (version === undefined) process.exit(0);
if (typeof version !== "string" || !/^(>=)?\d+\.\d+\.\d+$/.test(version)) process.exit(1);
console.log(version.replace(/^>=/, ""));
' "$PLATFORM_DIR/manifest.json" 2>/dev/null)"; then
  echo "FAIL requires.browser-farm 不是有效的最低版本"
  exit 1
fi
if [ -n "$REQUIRED_FARM" ]; then
  GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
  if GW_VER="$(GATEWAY_URL="$GATEWAY_URL" node -e '
const token = process.env.GATEWAY_TOKEN;
const endpoint = token ? "/v1/version" : "/v1/health";
const base = process.env.GATEWAY_URL.replace(/\/+$/, "");
const warn = message => { console.log("WARN " + message + "，跳过版本闸"); process.exitCode = 1; };
(async () => {
  const response = await fetch(base + endpoint, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    redirect: "manual",
    signal: AbortSignal.timeout(3000),
  });
  if (response.status !== 200) {
    await response.body?.cancel();
    return warn(`网关 ${endpoint} 返回 HTTP ${response.status}`);
  }
  const body = await response.json().catch(() => null);
  if (typeof body?.version !== "string" || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$/.test(body.version)) {
    return warn("网关响应无有效 version 字段");
  }
  console.log(body.version);
})().catch(() => warn("网关不可达"));
' 2>/dev/null)"; then
    if ver_ge "${GW_VER%%[-+]*}" "$REQUIRED_FARM"; then
      echo "PASS browser-farm ${GW_VER} >= ${REQUIRED_FARM}"
    else
      echo "FAIL browser-farm ${GW_VER} < 要求 ${REQUIRED_FARM}"
      echo
      echo "== 汇总: write=0 skip=0 fail=1 =="
      echo "INSTALL FAILED（农场版本不满足，未写任何文件）"
      exit 1
    fi
  else
    echo "${GW_VER:-WARN 无法读取网关版本，跳过版本闸}"
  fi
fi

# ---------------------------------------------------------------- 2. L2 前置双证
echo "-- 2. L2 前置（kualang-cbec 双证）"
L2_MISS=0
for f in "CHIEF-INIT.md" ".dsh/skills/ecom-selection/SKILL.md"; do
  if [ -f "$TARGET/$f" ]; then echo "  PASS $f"; else echo "  missing $f"; L2_MISS=1; fi
done
if [ "$L2_MISS" -eq 1 ]; then
  echo "FAIL 目标目录未装 L2（kualang-cbec），前置未满足"
  echo "     先跑：bash ../l2/install.sh \"$TARGET\""
  echo
  echo "== 汇总: write=$WROTE skip=$SKIPPED fail=1 =="
  echo "INSTALL FAILED（前置未满足，未写任何文件）"
  exit 1
fi
echo "PASS 目标目录已装 L2（双证齐）"

# ---------------------------------------------------------------- 3. 拷贝
DEST_REL="95-engine/platforms/$PLATFORM"
copy_file() { # src rel
  local src="$1" rel="$2" dest="$TARGET/$2"
  if [ -e "$dest" ]; then
    if [ "$FORCE" -eq 1 ]; then
      if cp "$src" "$dest"; then echo "  overwrite $rel"; WROTE=$((WROTE+1)); else echo "  FAIL      $rel"; FAILED=$((FAILED+1)); fi
    else
      echo "  skip      ${rel}（已存在，--force 覆盖）"; SKIPPED=$((SKIPPED+1))
    fi
    return
  fi
  mkdir -p "$(dirname "$dest")" || { echo "  FAIL      $rel"; FAILED=$((FAILED+1)); return; }
  if cp "$src" "$dest"; then echo "  write     $rel"; WROTE=$((WROTE+1)); else echo "  FAIL      $rel"; FAILED=$((FAILED+1)); fi
}

probe_file() { # rel
  if [ -e "$TARGET/$1" ]; then echo "  skip      $1（已存在）"; SKIPPED=$((SKIPPED+1)); else echo "  missing   $1（安装时会写）"; WROTE=$((WROTE+1)); fi
}

echo "-- 3. 平台包文件 → $DEST_REL/"
SRC_COUNT=0
while IFS= read -r rel; do
  SRC_COUNT=$((SRC_COUNT+1))
  if [ "$CHECK" -eq 1 ]; then probe_file "$DEST_REL/$rel"; else copy_file "$PLATFORM_DIR/$rel" "$DEST_REL/$rel"; fi
done < <(bash "$SRC/list-platform-files.sh" "$PLATFORM_DIR")
echo "  （源文件 $SRC_COUNT 个）"

# ---------------------------------------------------------------- 4. 落点校验
if [ "$CHECK" -eq 0 ]; then
  echo "-- 4. 落点校验"
  if [ -f "$TARGET/$DEST_REL/manifest.json" ]; then
    echo "PASS manifest 已落地（$DEST_REL/manifest.json）"
  else
    echo "FAIL manifest 未落地"; FAILED=$((FAILED+1))
  fi
  if [ -d "$TARGET/$DEST_REL/skills" ]; then
    echo "PASS skills/ 目录存在（$(find "$TARGET/$DEST_REL/skills" -type f | wc -l | tr -d ' ') 个文件）"
  else
    echo "FAIL skills/ 目录缺失"; FAILED=$((FAILED+1))
  fi
  GOT_COUNT="$(find "$TARGET/$DEST_REL" -type f | wc -l | tr -d ' ')"
  if [ "$GOT_COUNT" -eq "$SRC_COUNT" ]; then
    echo "PASS 落点文件数 $GOT_COUNT = 源文件数 $SRC_COUNT"
  else
    echo "FAIL 落点文件数 $GOT_COUNT != 源文件数 $SRC_COUNT"; FAILED=$((FAILED+1))
  fi
fi

# ---------------------------------------------------------------- 5. bundle 镜像一致性
if ! node "$SRC/check-bundle-skills.js" "$PLATFORM_DIR"; then
  FAILED=$((FAILED+1))
fi

echo
if [ "$CHECK" -eq 1 ]; then
  echo "== CHECK: would-write=$WROTE would-skip=$SKIPPED FAIL=$FAILED =="
  [ "$FAILED" -eq 0 ] && echo "CHECK OK（未写任何文件）" || echo "CHECK FAILED"
else
  echo "== 汇总: write=$WROTE skip=$SKIPPED fail=$FAILED =="
  if [ "$FAILED" -eq 0 ]; then
    echo "INSTALL OK"
    echo "下一步：平台参数在 $DEST_REL/overrides/platform.json（现值全是 null，等业务确认）。"
  else
    echo "INSTALL FAILED"
  fi
fi
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
