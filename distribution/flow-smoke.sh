#!/usr/bin/env bash
# 在临时工作区安装 L1/L2，并用随包样例运行四个业务脚本。
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; WARN=0
ok()  { PASS=$((PASS+1)); echo "  PASS $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

finish() {
  echo "== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN =="
  if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: READY"
    exit 0
  fi
  echo "RESULT: FAILED"
  exit 1
}

if ! WS="$(mktemp -d /tmp/dsh-ecom-flow.XXXXXX)"; then
  bad "无法创建临时工作区"
  finish
fi
trap 'rm -rf "$WS"' EXIT
trap 'exit 1' HUP INT TERM

echo "== dsh-ecom 业务流冒烟 =="
for layer in l1 l2; do
  if ! OUT="$(GATEWAY_TOKEN= bash "$SRC/$layer/install.sh" "$WS" 2>&1)"; then
    bad "$layer 安装失败"
    printf '%s\n' "$OUT"
    finish
  fi
  while IFS= read -r line; do
    WARN=$((WARN+1))
    printf '%s\n' "$line"
  done < <(printf '%s\n' "$OUT" | grep -E '^ *WARN ')
done

cd "$WS" || { bad "无法进入临时工作区"; finish; }
for name in candidates orders products messages; do
  if ! cp "data/$name.sample.csv" "data/$name.csv"; then
    bad "无法准备 data/$name.csv"
    finish
  fi
done

run_flow() {
  local script="$1" artifact="$2" out
  if ! out="$(python3 "scripts/$script.py" 2>&1)"; then
    bad "scripts/$script.py 执行失败"
    printf '%s\n' "$out"
  elif [ -f "$artifact" ] && [ -s "$artifact" ]; then
    ok "$artifact"
  elif [ -d "$artifact" ] && [ -n "$(find "$artifact" -type f -size +0c -print -quit)" ]; then
    ok "$artifact/"
  else
    bad "$artifact 缺失或为空"
    printf '%s\n' "$out"
  fi
}

run_flow score_products 'out/选品打分.csv'
run_flow gen_listing 'out/上架包'
run_flow ops_report 'out/运营日报.md'
run_flow cs_router 'out/客服处理.csv'
finish
