#!/usr/bin/env bash
# =============================================================================
# verify-dual-env.sh — 双环境验收（macOS+Rosetta / 原生 x86 Linux）
#
# 用法：
#   bash scripts/verify-dual-env.sh macos \
#     --image IMAGE_TAG --account ACCOUNT --port PORT --seed FP_SEED \
#     --tz TZ --lang LANG --data DATA_ROOT [--control CONTROL_URL] [--token TOKEN]
#
#   bash scripts/verify-dual-env.sh linux ...（同上，自动去掉 --platform 并加资源硬限）
#
# 前置：farm 目录可执行 node；docker 可用；image 已构建。
# =============================================================================
set -euo pipefail
ENV_KIND="${1:?usage: verify-dual-env.sh macos|linux ...}"; shift
IM=""; ACC=""; PORT=""; SEED=""; TZ="Asia/Tokyo"; LANG="ja-JP"; DATA="/DATA_ROOT"
CONTROL="http://127.0.0.1:19555"; TOKEN=""
# 简单解析（保持可读，不用 getopt）
while [ $# -gt 0 ]; do case "$1" in
  --image) IM="$2"; shift 2;; --account) ACC="$2"; shift 2;; --port) PORT="$2"; shift 2;;
  --seed) SEED="$2"; shift 2;; --tz) TZ="$2"; shift 2;; --lang) LANG="$2"; shift 2;;
  --data) DATA="$2"; shift 2;; --control) CONTROL="$2"; shift 2;; --token) TOKEN="$2"; shift 2;;
  *) echo "unknown arg $1"; exit 2;; esac; done
: "${IM:?--image}"; : "${ACC:?--account}"; : "${PORT:?--port}"; : "${SEED:?--seed}"
: "${TZ:=Asia/Tokyo}"; : "${LANG:=ja-JP}"; : "${DATA:=/DATA_ROOT}"

NAME="fp-${ACC//[:\/]/_}"
echo "== env=$ENV_KIND image=$IM account=$ACC port=$PORT seed=$SEED =="

echo "-- 1) 构建镜像"
if [ "$ENV_KIND" = "macos" ]; then
  docker build --platform linux/amd64 -t "$IM" ./docker
else
  docker build -t "$IM" ./docker
fi

echo "-- 2) 启动容器"
docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ "$ENV_KIND" = "macos" ]; then
  docker run -d --name "$NAME" --platform linux/amd64 \
    -p "127.0.0.1:${PORT}:9334" -e "FP_SEED=$SEED" -e "TZ=$TZ" -e "FP_LANG=$LANG" \
    -v "${DATA}/${ACC}:/data" "$IM" >/dev/null
else
  docker run -d --name "$NAME" --memory=1g --cpus=1 --shm-size=512m \
    -p "127.0.0.1:${PORT}:9334" -e "FP_SEED=$SEED" -e "TZ=$TZ" -e "FP_LANG=$LANG" \
    -v "${DATA}/${ACC}:/data" "$IM" >/dev/null
fi

echo "-- 3) 等 CDP"
for i in $(seq 1 20); do sleep 2; curl -s -m 3 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1 && break; done
curl -s "http://127.0.0.1:${PORT}/json/version" | grep -o '"Browser": *"[^"]*"'

echo "-- 4) attach 登记"
node farm.js attach --account "$ACC" --cdp "http://127.0.0.1:${PORT}" \
  --engine linux150 --tz "$TZ" --lang "$LANG" --seed "$SEED"

echo "-- 5) check（ip 走 FARM_IP_ECHO，无外网也能断言）"
FARM_IP_ECHO="${FARM_IP_ECHO:-http://127.0.0.1:19700/ip}" node farm.js check --account "$ACC"
echo "-- 6) dup（必须 collisions: []）"
node farm.js dup
echo "-- 7) control 健康"
curl -s -H "x-farm-token: ${TOKEN}" "${CONTROL}/health"; echo

echo "-- 8) 收尾（保留数据目录，容器可保留以便复用）"
echo "OK: env=$ENV_KIND account=$ACC cdp=http://127.0.0.1:${PORT}"
