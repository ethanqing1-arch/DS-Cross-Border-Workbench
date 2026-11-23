#!/bin/sh
set -eu
SEED="${FP_SEED:-5001}"
PORT="${PORT:-9333}"
PROFILE="${PROFILE:-/data/profile}"
PLATFORM="${FP_PLATFORM:-windows}"
LANG_TAG="${FP_LANG:-ja-JP}"
mkdir -p "$PROFILE"
Xvfb :99 -screen 0 1440x900x24 >/tmp/xvfb.log 2>&1 &
sleep 1
# Chrome 只监听 127.0.0.1，容器外访问不到 → 用 socat 转到 0.0.0.0:9334
socat TCP-LISTEN:9334,fork,reuseaddr TCP:127.0.0.1:9333 >/tmp/socat.log 2>&1 &
exec /opt/chrome/chrome \
  --no-sandbox --disable-dev-shm-usage \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$PORT" --remote-debugging-address=0.0.0.0 \
  --fingerprint="$SEED" \
  --fingerprint-platform="$PLATFORM" \
  --use-angle=swiftshader --enable-unsafe-swiftshader \
  --fingerprint-gpu-vendor="${FP_GPU_VENDOR:-Google Inc. (NVIDIA)}" \
  --fingerprint-gpu-renderer="${FP_GPU_RENDERER:-ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)}" \
  --fingerprint-hardware-concurrency=8 \
  --lang="$LANG_TAG" --accept-lang="$LANG_TAG" \
  --window-size=1440,900 about:blank
