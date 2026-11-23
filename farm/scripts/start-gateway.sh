#!/usr/bin/env bash
# =============================================================================
# start-gateway.sh — 起 farm-control + dsbot-gateway（真部署实例）
#
# 用法：
#   GATEWAY_TOKEN=xxx bash scripts/start-gateway.sh          # 前台起，Ctrl-C 停
#   GATEWAY_TOKEN=xxx bash scripts/start-gateway.sh --daemon  # 后台起，写 state/*.pid
#   bash scripts/start-gateway.sh --stop                     # 停后台实例
#   bash scripts/start-gateway.sh --status                   # 看状态
#
# 环境变量：
#   GATEWAY_TOKEN  必填，/v1/* 的 Bearer 令牌
#   FARM_TOKEN     可选，control 面的 x-farm-token；不设则 control 不鉴权（仅 127.0.0.1）
#   FARM_DB        可选，台账路径，默认 <farm>/state/farm.db
#   CONTROL_PORT   可选，默认 19555
#   GATEWAY_PORT   可选，默认 19671
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"; cd "$SRC" || exit 2

command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "找不到 node：装 Node 或手动 export PATH" >&2; exit 2; }

export FARM_DB="${FARM_DB:-$SRC/state/farm.db}"
CONTROL_PORT="${CONTROL_PORT:-19555}"
GATEWAY_PORT="${GATEWAY_PORT:-19671}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"
FARM_TOKEN="${FARM_TOKEN:-}"
export FARM_TOKEN   # control 子进程从环境变量读取，不走 argv
mkdir -p "$SRC/state"

CPIDF="$SRC/state/control.pid"; GPIDF="$SRC/state/gateway.pid"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

case "${1:-}" in
  --stop)
    for f in "$GPIDF" "$CPIDF"; do
      if alive "$f"; then kill "$(cat "$f")" 2>/dev/null && echo "已停 $(basename "$f" .pid) pid=$(cat "$f")"; fi
      rm -f "$f"
    done
    exit 0 ;;
  --status)
    echo "FARM_DB=$FARM_DB"
    for p in control gateway; do
      f="$SRC/state/$p.pid"
      if alive "$f"; then echo "$p: up pid=$(cat "$f")"; else echo "$p: down"; fi
    done
    exit 0 ;;
esac

[ -n "$GATEWAY_TOKEN" ] || { echo "GATEWAY_TOKEN 未设置，拒绝以无鉴权方式起网关" >&2; exit 2; }
# 只报长度，不打印令牌值；低于 32 位提示更换（openssl rand -hex 32 → 64 字符）
if [ "${#GATEWAY_TOKEN}" -lt 32 ]; then
  echo "提示：GATEWAY_TOKEN 长度 ${#GATEWAY_TOKEN} < 32，建议换成 openssl rand -hex 32 生成的 64 字符随机串" >&2
fi
export GATEWAY_TOKEN   # 网关子进程从环境变量读取，不走 argv
[ -f "$SRC/node_modules/ws/index.js" ] || { echo "缺依赖 ws：cd $SRC && npm i" >&2; exit 2; }

node ledger.js stats >/dev/null 2>&1 || { echo "台账打不开：$FARM_DB" >&2; exit 2; }

DAEMON=0; [ "${1:-}" = "--daemon" ] && DAEMON=1

ARGS_CTRL=(control.js --port "$CONTROL_PORT")

node "${ARGS_CTRL[@]}" >"$SRC/state/control.log" 2>&1 &
CPID=$!; echo $CPID > "$CPIDF"
sleep 1

node gateway/server.js --port "$GATEWAY_PORT" \
  --control "http://127.0.0.1:$CONTROL_PORT" \
  --farm "$SRC/farm.js" --driver "$SRC/driver.js" \
  >"$SRC/state/gateway.log" 2>&1 &
GPID=$!; echo $GPID > "$GPIDF"
sleep 1.2

echo "FARM_DB=$FARM_DB"
echo "control  pid=$CPID port=$CONTROL_PORT  log=state/control.log"
echo "gateway  pid=$GPID port=$GATEWAY_PORT  log=state/gateway.log"

if [ "$DAEMON" = "1" ]; then
  echo "后台运行。停：bash scripts/start-gateway.sh --stop"
  exit 0
fi

trap 'kill $GPID $CPID 2>/dev/null || true; rm -f "$CPIDF" "$GPIDF"' EXIT INT TERM
echo "前台运行。Ctrl-C 停。"
wait
