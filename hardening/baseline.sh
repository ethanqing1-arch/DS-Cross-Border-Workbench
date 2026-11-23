#!/usr/bin/env bash
# =============================================================================
# baseline.sh — 指纹基线快照与比对（升级前/后各跑一次）
#
# 用法：
#   bash baseline.sh snapshot                 # 生成快照到 evidence/baselines/<ts>/
#   bash baseline.sh snapshot --cdp http://127.0.0.1:19222   # 同时抓指纹 JSON
#   bash baseline.sh diff <ts_old> <ts_new>   # 比对两份快照
#   bash baseline.sh list
#
# 快照内容：app 版本 / asar sha256 / 内核目录清单 / assets 版本 / instances 数量
#          （可选）preflight --json 的完整指纹快照
# =============================================================================
set -uo pipefail

APP="${APP:-/Applications/ziniao.app}"
DATA="${DATA:-$HOME/Library/Application Support/ziniaobrowser}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/evidence/baselines"
mkdir -p "$BASE"

cmd="${1:-snapshot}"; shift || true
CDP=""
while [[ $# -gt 0 ]]; do
  case "$1" in --cdp) CDP="$2"; shift 2;; *) break;; esac
done

snapshot() {
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local d="$BASE/$ts"; mkdir -p "$d"

  # 1) app 版本 + asar 完整性基线
  { plutil -p "$APP/Contents/Info.plist" 2>/dev/null | grep -E 'CFBundleVersion|CFBundleShortVersionString|hash'
  } > "$d/app.txt"
  shasum -a 256 "$APP/Contents/Resources/app.asar" >> "$d/app.txt" 2>/dev/null

  # 2) 内核目录（Core 为空说明内核未下载）
  { ls -la "$DATA/env-kit/Core/" 2>/dev/null
    shasum -a 256 "$DATA"/env-kit/Core/* 2>/dev/null
  } > "$d/core.txt"

  # 3) 资产 / 扩展版本
  { echo "# assets-versions:"; ls -la "$DATA/assets-versions/" 2>/dev/null
    echo "# extensions:"; ls -la "$APP/Contents/Resources/app.asar.unpacked/assets/extensions/" 2>/dev/null
  } > "$d/assets.txt"

  # 4) 环境（user-data-dir）清单
  { echo "# instances:"; ls -1 "$DATA/instances/" 2>/dev/null
    echo "# running kernels:"; ps -Ao pid,command 2>/dev/null | grep -c -- '--user-data-dir' 
  } > "$d/instances.txt"

  # 5) 可选：指纹快照（需要已启动环境 + CDP 端口）
  if [[ -n "$CDP" ]]; then
    node "$ROOT/hardening/preflight.js" --cdp "$CDP" --json > "$d/fingerprint.json" 2>"$d/fingerprint.err" \
      && echo "fingerprint: captured" || echo "fingerprint: FAILED (see $d/fingerprint.err)"
  fi

  echo "$ts"
}

case "$cmd" in
  snapshot)
    ts="$(snapshot | tail -1)"
    echo "snapshot: $BASE/$ts" >&2   # 人类可读信息走 stderr
    echo "$ts"                      # stdout 只给机读的 ts，便于脚本取用
    ;;
  list) ls -1 "$BASE" ;;
  diff)
    a="${1:-}"; b="${2:-}"
    [[ -d "$BASE/$a" && -d "$BASE/$b" ]] || { echo "usage: baseline.sh diff <old_ts> <new_ts>"; exit 2; }
    for f in app.txt core.txt assets.txt instances.txt; do
      if ! diff -q "$BASE/$a/$f" "$BASE/$b/$f" >/dev/null 2>&1; then
        echo "=== CHANGED: $f ==="
        diff -u "$BASE/$a/$f" "$BASE/$b/$f" | sed -n '1,40p'
      fi
    done
    if [[ -f "$BASE/$a/fingerprint.json" && -f "$BASE/$b/fingerprint.json" ]]; then
      python3 - "$BASE/$a/fingerprint.json" "$BASE/$b/fingerprint.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sa=a.get("snapshot",{}); sb=b.get("snapshot",{})
keys=["ua","platform","tz","tzOffsetMin","fonts","hc","dm","screen","webdriver","plugins"]
diff=[k for k in keys if json.dumps(sa.get(k),sort_keys=True)!=json.dumps(sb.get(k),sort_keys=True)]
print("=== 指纹差异 ===")
for k in diff: print(f"  {k}: {sa.get(k)}  ->  {sb.get(k)}")
if not diff: print("  无不一致（指纹稳定）")
PY
    fi
    ;;
  *) echo "usage: baseline.sh {snapshot [--cdp URL]|diff <old> <new>|list}"; exit 2 ;;
esac
