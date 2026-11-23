#!/usr/bin/env bash
# =============================================================================
# preflight-build.sh — 自编译 fingerprint-chromium 的前置体检（GO / NO-GO）
# 在目标构建机上跑一遍，缺什么一眼看到。
# =============================================================================
set -uo pipefail
FAIL=0
ok(){ printf "  \033[32mOK\033[0m   %s\n" "$1"; }
no(){ printf "  \033[31mNO\033[0m   %s\n" "$1"; FAIL=1; }
warn(){ printf "  \033[33mWARN\033[0m %s\n" "$1"; }

echo "== 1. 工具链 =="
command -v xcodebuild >/dev/null && ok "xcodebuild $(xcodebuild -version 2>/dev/null | head -1)" || no "缺 Xcode（CLT 不够）"
command -v git >/dev/null && ok "git $(git --version | awk '{print $3}')" || no "缺 git"
command -v python3 >/dev/null && ok "python3 $(python3 -V 2>&1 | awk '{print $2}')" || no "缺 python3"

echo "== 2. 资源 =="
AVAIL=$(df -g . | awk 'NR==2{print $4}')
[ "${AVAIL:-0}" -ge 120 ] && ok "磁盘剩余 ${AVAIL} GB（需 ≥120）" || no "磁盘仅 ${AVAIL} GB（需 ≥120）"
MEM=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
[ "$MEM" -ge 16 ] && ok "内存 ${MEM} GB" || warn "内存 ${MEM} GB（16 GB 以下会很慢）"
ok "CPU $(sysctl -n hw.ncpu 2>/dev/null)"

echo "== 3. 网络（构建真正会卡的就在这里）=="
check(){ code=$(curl -s -m 8 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null | tr -dc '0-9')
  if printf '%s' "$code" | grep -Eq '^[1-5][0-9][0-9]$'; then ok "$2 → $code"; else no "$2 → 不可达（$1）"; fi; }
check https://chromium.googlesource.com/          "Chromium 源码 / gclient 依赖"
check https://chrome-infra-packages.appspot.com/ "CIPD 工具链（clang/gn/ninja）"
check https://storage.googleapis.com/            "GCS 产物/缓存"
check https://github.com/chromium/chromium       "GitHub 源码镜像（备选）"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "== GO：可以构建 =="
  echo "下一步：bash build-fp-chromium.sh 150.0.7871.186"
else
  echo "== NO-GO：先解决上面标红项 =="
  echo "提示：googlesource / CIPD 被墙时，Chromium 无法 fetch 依赖，换构建机或走代理。"
fi
exit "$FAIL"
