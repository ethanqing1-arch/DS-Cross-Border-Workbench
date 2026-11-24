#!/usr/bin/env bash
# =============================================================================
# install.sh — kualang-cbec（L2 跨境电商版本包）工作区安装器
#
# 用法：
#   bash install.sh <目标目录>             # 非破坏安装：已存在默认跳过
#   bash install.sh <目标目录> --force     # 覆盖已存在的同名文件
#   bash install.sh <目标目录> --check     # 只校验，不写任何文件
#
# 环境变量：
#   GATEWAY_URL    默认 http://127.0.0.1:19671
#   GATEWAY_TOKEN  可选；/v1/version 需要鉴权，未设时退回免鉴权的 /v1/health 读 version
#   REQUIRED_FARM  默认 1.1.0
#
# 边界：只写 <目标目录>；不碰 ~/ds-bot-workspace、不碰 DS Bot 状态、不安装 bundle。
# =============================================================================
set -uo pipefail
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET=""; CHECK=0; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "未知参数：${arg}（可用 --check / --force）" >&2; exit 2 ;;
    *) TARGET="$arg" ;;
  esac
done
[ -n "$TARGET" ] || { echo "用法：bash install.sh <目标目录> [--check] [--force]" >&2; exit 2; }

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:19671}"
REQUIRED_FARM="${REQUIRED_FARM:-1.1.0}"
WROTE=0; SKIPPED=0; FAILED=0

# ---------------------------------------------------------------- 版本比较
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

# ---------------------------------------------------------------- 网关版本闸
# 结果写进 GW_RESULT(ok|warn|fail) / GW_VER / GW_MSG
gw_probe() {
  GW_RESULT=ok; GW_VER=""; GW_MSG=""
  local tmp code auth
  tmp="$(mktemp)"
  if [ -n "${GATEWAY_TOKEN:-}" ]; then
    code="$(printf 'Authorization: Bearer %s\n' "$GATEWAY_TOKEN" | curl -sS --max-time 3 -o "$tmp" -w '%{http_code}' -H @- "${GATEWAY_URL%/}/v1/version" 2>/dev/null)"
  else
    code="$(curl -sS --max-time 3 -o "$tmp" -w '%{http_code}' "${GATEWAY_URL%/}/v1/version" 2>/dev/null)"
  fi
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    rm -f "$tmp"; GW_RESULT=warn; GW_MSG="网关不可达（${GATEWAY_URL}），跳过版本闸"; return
  fi
  # 401 或路由缺失时退回免鉴权的 /v1/health（它同样带 version 字段）
  if [ "$code" != "200" ]; then
    local first_code="$code"
    if code="$(curl -sS --max-time 3 -o "$tmp" -w '%{http_code}' "${GATEWAY_URL%/}/v1/health" 2>/dev/null)" && [ "$code" = "200" ]; then
      :
    elif [ -z "$code" ] || [ "$code" = "000" ]; then
      rm -f "$tmp"; GW_RESULT=warn; GW_MSG="网关 /v1/version 返回 HTTP ${first_code} 且 /v1/health 不可达（${GATEWAY_URL}），跳过版本闸"; return
    else
      rm -f "$tmp"; GW_RESULT=warn; GW_MSG="网关返回 HTTP ${code}，跳过版本闸"; return
    fi
  fi
  GW_VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" | head -1)"
  rm -f "$tmp"
  if [ -z "$GW_VER" ]; then GW_RESULT=warn; GW_MSG="网关响应无 version 字段，跳过版本闸"; return; fi
  if ver_ge "$GW_VER" "$REQUIRED_FARM"; then
    GW_RESULT=ok; GW_MSG="browser-farm ${GW_VER} >= ${REQUIRED_FARM}"
  else
    GW_RESULT=fail; GW_MSG="browser-farm ${GW_VER} < 要求 ${REQUIRED_FARM}"
  fi
}

# ---------------------------------------------------------------- 安装动作
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

ensure_dir() { # rel
  local dest="$TARGET/$1"
  if [ -d "$dest" ]; then
    echo "  skip      $1/（已存在）"; SKIPPED=$((SKIPPED+1))
  else
    if mkdir -p "$dest"; then echo "  mkdir     $1/"; WROTE=$((WROTE+1)); else echo "  FAIL      $1/"; FAILED=$((FAILED+1)); fi
  fi
}

# 只统计、不写：返回 would-write / would-skip
probe_file() { # rel
  if [ -e "$TARGET/$1" ]; then echo "  skip      $1（已存在）"; SKIPPED=$((SKIPPED+1)); else echo "  missing   $1（安装时会写）"; WROTE=$((WROTE+1)); fi
}

# ---------------------------------------------------------------- 预检
[ -f "$SRC/manifest.json" ] || { echo "缺 manifest.json，不是完整的 L2 包" >&2; exit 2; }
[ -d "$SRC/workspace" ] || { echo "缺 workspace/，不是完整的 L2 包" >&2; exit 2; }
[ -d "$SRC/skills" ] || { echo "缺 skills/，不是完整的 L2 包" >&2; exit 2; }

echo "== kualang-cbec $(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/manifest.json" | head -1) =="
echo "目标：$TARGET"
echo "模式：$([ "$CHECK" -eq 1 ] && echo '只校验（--check）' || { [ "$FORCE" -eq 1 ] && echo '安装（--force）' || echo '安装（非破坏）'; })"

if ! EXPECTED_SKILLS="$(find "$SRC/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"; then
  echo "FAIL 无法统计 skills/ 目录" >&2
  exit 2
fi
MANIFEST_SKILLS="$EXPECTED_SKILLS"
if command -v node >/dev/null 2>&1; then
  if ! MANIFEST_SKILLS="$(node -e '
const m = require(process.argv[1]);
if (!m.name || !m.version || !m.requires || !m.requires["browser-farm"] ||
    !m.contents || !Array.isArray(m.contents.skills)) process.exit(1);
console.log(m.contents.skills.length);
' "$SRC/manifest.json" 2>/dev/null)"; then
    echo "FAIL manifest 不可解析或字段不全" >&2
    exit 2
  fi
  echo "PASS manifest 可解析（name/version/requires.browser-farm/contents.skills）"
else
  echo "WARN 缺 node，跳过 manifest 校验"
fi

echo "-- 网关版本闸"
gw_probe
case "$GW_RESULT" in
  ok)   echo "PASS $GW_MSG" ;;
  warn) echo "WARN $GW_MSG" ;;
  fail) echo "FAIL $GW_MSG"; FAILED=$((FAILED+1)) ;;
esac

echo "-- 空骨架目录"
while IFS= read -r rel; do
  if [ "$CHECK" -eq 1 ]; then
    [ -d "$TARGET/$rel" ] && { echo "  skip      $rel/（已存在）"; SKIPPED=$((SKIPPED+1)); } || { echo "  missing   $rel/（安装时会建）"; WROTE=$((WROTE+1)); }
  else
    ensure_dir "$rel"
  fi
done < <(cd "$SRC/workspace" && find . -type d ! -name . | sed 's|^\./||' | sort)

echo "-- 工作区文件"
while IFS= read -r rel; do
  if [ "$CHECK" -eq 1 ]; then probe_file "$rel"; else copy_file "$SRC/workspace/$rel" "$rel"; fi
done < <(cd "$SRC/workspace" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | sort)

echo "-- 业务 skills"
SKILL_COUNT=0
for d in "$SRC"/skills/*; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"; SKILL_COUNT=$((SKILL_COUNT+1))
  if [ ! -f "$d/SKILL.md" ]; then
    echo "  FAIL      skills/$name/SKILL.md 缺失"; FAILED=$((FAILED+1))
  fi
  while IFS= read -r -d '' file; do
    rel=".dsh/skills/$name/${file#./}"
    if [ "$CHECK" -eq 1 ]; then probe_file "$rel"; else copy_file "$d/$file" "$rel"; fi
  done < <(cd "$d" && find . -type f -print0 | sort -z)
done
if [ "$SKILL_COUNT" -eq "$EXPECTED_SKILLS" ] && [ "$SKILL_COUNT" -eq "$MANIFEST_SKILLS" ]; then
  echo "PASS skills=${SKILL_COUNT}（期望 ${EXPECTED_SKILLS}）"
else
  echo "FAIL skills=${SKILL_COUNT}（目录 ${EXPECTED_SKILLS}，manifest ${MANIFEST_SKILLS}）"
  FAILED=$((FAILED+1))
fi

echo "-- bundle 镜像一致性"
if DRIFT="$(diff -qr "$SRC/skills" "$SRC/bundle/skills" 2>&1)"; then
  echo "PASS bundle/skills 与 skills/ 一致"
else
  echo "FAIL bundle/skills 与 skills/ 不一致"
  printf '%s\n' "$DRIFT"
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
    echo "下一步：把 DS Bot 工作区指到 ${TARGET}；再由 Main Bot 按 SEED.md 播种 bot 与群。"
  else
    echo "INSTALL FAILED"
  fi
fi
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
