#!/usr/bin/env bash
# =============================================================================
# sync-l2-skill.sh — 把仓库 L2 的业务 skill 同步到 DS Bot 运行时目录
#
# 用法：
#   bash scripts/sync-l2-skill.sh <skill-name>           # 单向同步：仓库 -> ~/.ds-bot/skills/
#   bash scripts/sync-l2-skill.sh <skill-name> --check   # 只比对，不写文件
#
# 环境变量：
#   DSBOT_SKILLS_DIR   目标根目录，默认 ~/.ds-bot/skills
#
# 边界：只写 <目标根>/<skill-name>/；只增改、不删除（目标侧多余文件保留并提示）。
#       不碰工作区、不碰 DS Bot 应用状态、不安装 bundle、不碰 farm。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_ROOT="$ROOT/distribution/l2/skills"
DEST_ROOT="${DSBOT_SKILLS_DIR:-$HOME/.ds-bot/skills}"

NAME=""; CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "未知参数：$arg（可用 --check / --help）" >&2; exit 2 ;;
    *) NAME="$arg" ;;
  esac
done

[ -n "$NAME" ] || { echo "用法：bash scripts/sync-l2-skill.sh <skill-name> [--check]" >&2; exit 2; }

SRC="$SRC_ROOT/$NAME"
[ -d "$SRC" ] || { echo "FAIL 仓库里没有这个 skill：$SRC" >&2; exit 2; }
[ -f "$SRC/SKILL.md" ] || { echo "FAIL $NAME 缺 SKILL.md，不是完整 skill" >&2; exit 2; }

DEST="$DEST_ROOT/$NAME"

# ---------------------------------------------------------------- 只比对
if [ "$CHECK" -eq 1 ]; then
  [ -d "$DEST" ] || { echo "MISSING $DEST（目标侧还没装，先不带 --check 跑一次）" >&2; exit 1; }
  if DIFF="$(diff -r "$SRC" "$DEST" 2>&1)"; then
    echo "OK $NAME 与 $DEST 完全一致"
    exit 0
  fi
  echo "DRIFT $NAME 与 $DEST 不一致：" >&2
  printf '%s\n' "$DIFF" >&2
  exit 1
fi

# ---------------------------------------------------------------- 同步
mkdir -p "$DEST" || { echo "FAIL 无法创建 $DEST" >&2; exit 1; }

if command -v rsync >/dev/null 2>&1; then
  # 不带 --delete：只增改，不删目标侧文件
  rsync -a --exclude='.DS_Store' "$SRC/" "$DEST/" || { echo "FAIL rsync 失败" >&2; exit 1; }
else
  cp -R "$SRC/." "$DEST/" || { echo "FAIL cp 失败" >&2; exit 1; }
fi

echo "SYNCED $SRC -> $DEST"

# 目标侧多出来的文件：只提示，不删
EXTRA="$(diff -rq "$SRC" "$DEST" 2>&1 | grep -F "Only in $DEST" || true)"
if [ -n "$EXTRA" ]; then
  echo "NOTE 目标侧存在仓库里没有的文件，已保留未删除："
  printf '%s\n' "$EXTRA"
fi

if STILL="$(diff -r "$SRC" "$DEST" 2>&1)"; then
  echo "OK 同步后逐文件一致"
else
  echo "WARN 同步后仍有差异（上面 NOTE 列出的多余文件会造成这个结果）：" >&2
  printf '%s\n' "$STILL" >&2
fi
