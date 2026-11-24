#!/usr/bin/env bash
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)" || exit 1

usage() {
  echo '用法：bash distribution/install-all.sh <目标目录> [--all-platforms] [--check]'
  echo '默认安装 Amazon。--check 检查已有工作区，L3 仍要求目标已装 L2。'
}

target=""
all=0
check=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --all-platforms) all=1 ;;
    --check) check=1 ;;
    -*) usage >&2; exit 2 ;;
    *)
      if [ -n "$target" ]; then usage >&2; exit 2; fi
      target="$arg"
      ;;
  esac
done
[ -n "$target" ] || { usage >&2; exit 2; }

passed=0
failed_step() {
  local step="$1" status="$2"
  shift 2
  printf 'FAIL %s（退出码 %s）\n失败命令：' "$step" "$status" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  echo '下一步：bash distribution/doctor.sh'
  echo "RESULT: NOT_READY（PASS=$passed FAIL=1）"
  exit "$status"
}

run_step() {
  local step="$1"
  shift
  if [ "$check" -eq 1 ]; then set -- "$@" --check; fi
  echo "== $step =="
  if "$@" 2>&1; then
    echo "PASS $step"
    passed=$((passed+1))
  else
    failed_step "$step" "$?" "$@"
  fi
}

run_step L1 bash "$SRC/l1/install.sh" "$target"
run_step L2 bash "$SRC/l2/install.sh" "$target"

if [ "$all" -eq 1 ]; then
  list_command=(bash "$SRC/l3/install.sh" --list)
  if listing="$("${list_command[@]}" 2>&1)"; then
    platforms="$(printf '%s\n' "$listing" | awk 'NR > 1 && NF {print $1}')"
    if [ -z "$platforms" ]; then
      printf '%s\n' "$listing" >&2
      failed_step 'L3 平台清单为空' 1 "${list_command[@]}"
    fi
  else
    status=$?
    printf '%s\n' "$listing" >&2
    failed_step 'L3 平台清单' "$status" "${list_command[@]}"
  fi
else
  platforms=amazon
fi

while IFS= read -r platform; do
  run_step "L3 $platform" bash "$SRC/l3/install.sh" "$platform" "$target"
done <<< "$platforms"

if [ "$all" -eq 0 ]; then echo '默认平台：amazon。全平台使用 --all-platforms。'; fi
echo '下一步：bash distribution/verify.sh'
echo "RESULT: READY（PASS=$passed FAIL=0）"
