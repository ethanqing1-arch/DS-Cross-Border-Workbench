#!/usr/bin/env bash
# 即使用 bash -x 调用，也不跟踪令牌检查。
set +x
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
failures=0
pass() { printf 'PASS %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { failures=$((failures+1)); printf 'FAIL %s\n' "$*"; }
finish() {
  if [ "$failures" -eq 0 ]; then
    echo 'RESULT: READY'
    exit 0
  fi
  echo 'RESULT: NOT_READY'
  exit 1
}

if platform="$(uname -s -m 2>/dev/null)"; then
  case "$platform" in
    MINGW*|MSYS*|CYGWIN*)
      fail "系统/架构：${platform}，Windows 原生环境不支持，见 docs/external-setup.md §8"
      finish
      ;;
    *) pass "系统/架构：$platform" ;;
  esac
else
  fail '无法读取系统/架构（uname -s -m）'
fi

if [ "${BASH_VERSINFO[0]}" -lt 3 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  fail "bash ${BASH_VERSION}，需要 3.2 或更新版本"
  finish
else
  pass "bash $BASH_VERSION"
fi

if ! command -v node >/dev/null 2>&1; then
  fail 'PATH 里找不到 node。Apple Silicon 的 Homebrew 安装通常在 /opt/homebrew/bin。'
elif node_version="$(node -v 2>/dev/null)" && [[ "$node_version" =~ ^v([0-9]+)\. ]] &&
     [ "${BASH_REMATCH[1]}" -ge 18 ]; then
  pass "node $node_version"
else
  fail "node ${node_version:-版本不可读}，需要主版本 ≥18"
fi

if command -v python3 >/dev/null 2>&1; then
  python_version="$(python3 -V 2>&1)" || python_version='版本不可读'
  pass "python3（${python_version}）"
else
  fail 'PATH 里找不到 python3'
fi

for tool in git curl tar; do
  if tool_path="$(command -v "$tool")" && "$tool" --version >/dev/null 2>&1; then
    pass "${tool}（${tool_path}）"
  else
    fail "$tool 不可用"
  fi
done

available="$(LC_ALL=C df -Pk . 2>/dev/null | awk 'NR == 2 {print $4}')" || available=""
if [[ "$available" =~ ^[0-9]+$ ]]; then
  if [ "$available" -lt 1048576 ]; then
    warn "当前目录可用空间 ${available} KiB，低于 1 GiB"
  else
    pass "当前目录可用空间 ${available} KiB（至少 1 GiB）"
  fi
else
  warn '无法读取当前目录可用空间（df -Pk .）'
fi

listeners_known=1
if sockets="$(LC_ALL=C ss -H -ltn 2>/dev/null)"; then
  listeners="$(printf '%s\n' "$sockets" | awk '{print $4}')"
elif sockets="$(LC_ALL=C netstat -an 2>/dev/null)"; then
  listeners="$(printf '%s\n' "$sockets" | awk '/^tcp/ && $NF == "LISTEN" {print $4}')"
else
  listeners_known=0
fi
for port in 19671 19555; do
  if [ "$listeners_known" -eq 0 ]; then
    warn "无法检查 TCP $port（ss/netstat 不可用）"
  elif printf '%s\n' "$listeners" | awk -v port="$port" '$0 ~ ("[.:]" port "$") {found=1} END {exit !found}'; then
    warn "TCP $port 已被占用，可能已有农场在运行"
  else
    pass "TCP $port 未监听"
  fi
done

token_length=0
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  token_length="${#GATEWAY_TOKEN}"
elif [ -n "${DSH_SECRET_GATEWAY_TOKEN:-}" ]; then
  token_length="${#DSH_SECRET_GATEWAY_TOKEN}"
fi
if [ "$token_length" -eq 0 ]; then
  warn '未设置 GATEWAY_TOKEN 或 DSH_SECRET_GATEWAY_TOKEN'
elif [ "$token_length" -lt 32 ]; then
  warn '网关令牌少于 32 个字符'
else
  pass '网关令牌长度至少 32 个字符'
fi

if [ -f "$ROOT/farm/node_modules/ws/package.json" ]; then
  pass 'farm/node_modules/ws 已就绪'
else
  warn '缺 farm/node_modules/ws，请在 farm/ 运行 npm install'
fi

if [ -x "${HOME:-}/.dsh/venvs/camoufox/bin/python" ]; then
  pass 'Camoufox Python 已就绪'
else
  warn '缺 ~/.dsh/venvs/camoufox/bin/python，Camoufox 任务不可用'
fi

finish
