#!/usr/bin/env bash
# =============================================================================
# build-fp-chromium.sh — 自编译 fingerprint-chromium（macOS arm64）
#
# 现实约束（2026-11 实测，两条都是硬阻塞）：
#   1) 本机 googlesource / CIPD 不可达（preflight-build.sh 会判 NO-GO）；
#   2) 上游「延迟发布源码」：150 的 tag 里只有 README，最新可构建的是 148。
#      → 148 恰好就是我们已装的那个二进制，所以"自编译换新版本"目前无解。
#
# 用法：
#   bash build-fp-chromium.sh --check 150.0.7871.186   # 只查源码是否已发布
#   bash build-fp-chromium.sh 148.0.7778.215            # 完整流程（需 GO 环境）
# =============================================================================
set -euo pipefail
REPO=adryfish/fingerprint-chromium
MODE="${1:-}"
TAG="${2:-}"; [ "$MODE" = "--check" ] || TAG="$MODE"
[ -n "$TAG" ] || { echo "usage: $0 [--check] <tag>"; exit 2; }

api_contents() {
  if command -v gh >/dev/null; then gh api "repos/$REPO/contents/?ref=$1" --jq '.[].name' 2>/dev/null
  else curl -s "https://api.github.com/repos/$REPO/contents/?ref=$1" | python3 -c 'import json,sys;print("\n".join(x["name"] for x in json.load(sys.stdin)))' 2>/dev/null; fi
}

echo "== 源码可用性：$TAG =="
NAMES=$(api_contents "$TAG" || true)
if printf '%s\n' "$NAMES" | grep -qx 'chromium_version.txt'; then
  echo "  OK  源码已发布（含 patches/utils/chromium_version.txt）"
else
  echo "  NO  该 tag 只有文档，没有源码 —— 上游延迟发布策略"
  echo "      tag 内容：$(printf '%s' "$NAMES" | tr '\n' ' ')"
  echo "      最新可构建版本请查：https://github.com/$REPO/tags"
  [ "$MODE" = "--check" ] && exit 3 || exit 3
fi
[ "$MODE" = "--check" ] && exit 0

echo "== 环境体检 =="
bash "$(dirname "$0")/preflight-build.sh" || { echo "环境 NO-GO，终止"; exit 4; }

WORK="${WORK:-$HOME/fp-build}"; SRC="$WORK/fingerprint-chromium"
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" "https://github.com/$REPO.git" "$SRC"
fi
cd "$SRC"
grep -q "$TAG" chromium_version.txt && echo "  OK  源码树版本一致：$(cat chromium_version.txt)"

cat <<'GUIDE'

== 机械部分已完成，接下来按上游文档执行（版本相关，脚本不代跑）==
   1) depot_tools（需能访问 googlesource）：
        git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/depot_tools
        export PATH="$HOME/depot_tools:$PATH"
   2) 按 ungoogled-chromium 的 macOS 构建文档拉 Chromium 与工具链：
        https://github.com/ungoogled-software/ungoogled-chromium/blob/master/docs/building.md
      （把其中的 ungoogled-chromium 子模块地址替换为本仓库）
   3) 产物：Chromium.app → farm.js --chrome <该二进制>
GUIDE
