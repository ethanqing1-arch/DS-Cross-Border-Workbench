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

if ! WS="$(mktemp -d /tmp/kualang-flow.XXXXXX)"; then
  bad "无法创建临时工作区"
  finish
fi
trap 'rm -rf "$WS"' EXIT
trap 'exit 1' HUP INT TERM

echo "== kualang 业务流冒烟 =="
for layer in l1 l2; do
  if ! OUT="$(bash "$SRC/$layer/install.sh" "$WS" 2>&1)"; then
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

check_content() {
  local artifact="$1" out
  if out="$(python3 - "$artifact" 2>&1 <<'PY'
import csv
import sys
from pathlib import Path


def read_rows(path):
    with path.open(encoding="utf-8-sig", newline="") as file:
        return list(csv.DictReader(file))


artifact = Path(sys.argv[1])
if artifact.name == "选品打分.csv":
    rows = read_rows(artifact)
    decisions = [row.get("决策") for row in rows]
    red_flags = [row.get("红线") for row in rows if row.get("决策") == "放弃"]
    if not {"上架测试", "放弃"}.issubset(decisions) or any(
        not (flag or "").strip() for flag in red_flags
    ):
        sys.exit(f"实际决策={decisions!r}，放弃行红线={red_flags!r}")
elif artifact.name == "上架包":
    count = sum(path.is_file() for path in artifact.rglob("*.md"))
    import_table = artifact.with_name("平台导入表.csv")
    size = import_table.stat().st_size if import_table.is_file() else 0
    if count < 2 or size == 0:
        sys.exit(f"实际 .md 文件数={count}，平台导入表.csv 字节数={size}")
elif artifact.name == "运营日报.md":
    report = artifact.read_text(encoding="utf-8")
    terms = ["GMV", "退款率", "贡献利润"]
    found = [term for term in terms if term in report]
    if found != terms:
        missing = [term for term in terms if term not in found]
        sys.exit(f"正文实际包含={found!r}，缺少={missing!r}")
elif artifact.name == "客服处理.csv":
    routed = [row.get("是否转人工") for row in read_rows(artifact)]
    if not {"是", "否"}.issubset(routed):
        sys.exit(f"实际是否转人工={routed!r}")
else:
    sys.exit(f"没有为 {artifact} 配置内容校验")
PY
)"; then
    ok "$artifact 内容校验"
  else
    bad "$artifact 内容校验失败"
    printf '%s\n' "$out"
  fi
}

check_incomplete_scores() {
  local out detail
  if ! cat > data/candidates.csv <<'CSV'
品类,商品名,预估售价,头部评论数
家居,MateeyLife 慢食碗,7.64,10819
家居,Outward Hound 慢食碗,6.39,135893
CSV
  then
    bad "无法准备打分缺列样例"
    return
  fi
  if ! out="$(python3 scripts/score_products.py 2>&1)"; then
    bad "打分缺列样例执行失败"
  elif printf '%s\n' "$out" | grep -Eq '上架测试|小批量观察'; then
    bad "打分缺列样例出现正向决策"
  elif ! detail="$(python3 - 'out/选品打分.csv' 2>&1 <<'PY'
import csv
import sys

with open(sys.argv[1], encoding="utf-8-sig", newline="") as file:
    rows = list(csv.DictReader(file))
empty = ("表面毛利", "贡献利润", "贡献利润率", "分层", "月搜索量", "在售竞品数", "供需比", "退货率", "总分")
if len(rows) != 2 or any(
    (row["决策"], row["证据等级"], row["可算维度"]) != ("补数据", "D", "0/4")
    or any(row[field] for field in empty)
    or not all(term in row["缺口"] for term in ("需求", "竞争", "利润未验", "风险", "1688进价", "运费"))
    or "利润未验" not in row["诊断"]
    for row in rows
):
    sys.exit(f"实际打分明细：{rows!r}")
PY
)"; then
    bad "打分缺列样例的决策、空白指标或缺失诊断不符"
    printf '%s\n' "$detail"
  else
    ok "打分缺列样例两行均为 D、0/4、补数据，未输出正向决策"
    return
  fi
  printf '%s\n' "$out"
}

run_flow score_products 'out/选品打分.csv'
check_content 'out/选品打分.csv'
run_flow gen_listing 'out/上架包'
check_content 'out/上架包'
run_flow ops_report 'out/运营日报.md'
check_content 'out/运营日报.md'
run_flow cs_router 'out/客服处理.csv'
check_content 'out/客服处理.csv'
check_incomplete_scores
finish
