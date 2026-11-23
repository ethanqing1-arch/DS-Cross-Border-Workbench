#!/usr/bin/env bash
# =============================================================================
# ledger-clean.sh — 台账账号清理：默认 dry-run，--apply 才真删
#
# 用法：
#   bash scripts/ledger-clean.sh --account 'probe:health:%'            # 只看会删什么
#   bash scripts/ledger-clean.sh --account 'probe:health:%' --apply    # 真删（先备份）
#   bash scripts/ledger-clean.sh --account '%:e2e-smoke' --apply
#   bash scripts/ledger-clean.sh --all-stopped --apply                 # 所有非 running 行
#   bash scripts/ledger-clean.sh --db /tmp/t.db --all-stopped          # 指定库（自检用）
#
# 两道拒删闸（任一成立直接退出 1，一个字节都不写库）：
#   1) 网关/control 还在跑：GATEWAY_PORT(默认 19671) 或 CONTROL_PORT(默认 19555) 有 LISTEN
#      → 先 bash scripts/start-gateway.sh --stop
#   2) accounts 里有 status='running' 的行，或 pid 仍然活着（kill -0）的行
#
# 备份：sqlite3 ".backup '<db>.bak-YYYYmmdd-HHMMSS'"——库是 WAL 模式，cp 可能拿到半写状态
# 选择器：--account <LIKE> 或 --all-stopped，二选一；不做无条件全删
# 退出码：0 正常（dry-run 或已删）；1 拒绝/出错；2 用法错
# 边界：只删 accounts 行；checks 历史保留（按账号仍可回查）
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"; cd "$SRC" || exit 2
GATEWAY_PORT="${GATEWAY_PORT:-19671}"
CONTROL_PORT="${CONTROL_PORT:-19555}"

DB=""; ACCOUNT_LIKE=""; ALL_STOPPED=0; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --db)          DB="${2:-}"; shift 2 ;;
    --account)     ACCOUNT_LIKE="${2:-}"; shift 2 ;;
    --all-stopped) ALL_STOPPED=1; shift ;;
    --apply)       APPLY=1; shift ;;
    -h|--help)     sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "用法错：未知参数 $1（--help 看用法）" >&2; exit 2 ;;
  esac
done

if [ -n "$ACCOUNT_LIKE" ] && [ "$ALL_STOPPED" = "1" ]; then
  echo "用法错：--account 与 --all-stopped 只能二选一" >&2; exit 2
fi
if [ -z "$ACCOUNT_LIKE" ] && [ "$ALL_STOPPED" != "1" ]; then
  echo "用法错：必须给 --account <LIKE> 或 --all-stopped（不做无条件全删）" >&2; exit 2
fi
if [ -z "$DB" ]; then DB="${FARM_DB:-$SRC/state/farm.db}"; fi
DB="$(cd "$(dirname "$DB")" 2>/dev/null && pwd)/$(basename "$DB")" \
  || { echo "用法错：台账目录不存在" >&2; exit 2; }
[ -f "$DB" ] || { echo "台账不存在：$DB（服务实际用 $SRC/state/farm.db）" >&2; exit 2; }
command -v sqlite3 >/dev/null 2>&1 || { echo "找不到 sqlite3（macOS 自带 /usr/bin/sqlite3）" >&2; exit 2; }

echo "台账：$DB"

# ---- 闸 1：服务还在跑就别动库 ----------------------------------------------
for pair in "gateway:$GATEWAY_PORT" "control:$CONTROL_PORT"; do
  name="${pair%%:*}"; port="${pair##*:}"
  pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | tr '\n' ' ')"
  elif command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    pids="(nc)"
  fi
  if [ -n "${pids// /}" ]; then
    echo "拒绝：$name 还在跑（端口 $port，pid: ${pids% }）。先 bash scripts/start-gateway.sh --stop" >&2
    exit 1
  fi
done

# ---- 闸 2：有 running / pid 还活着的行就别删 --------------------------------
running_rows="$(sqlite3 -json "$DB" "SELECT account,status,pid FROM accounts WHERE status='running' ORDER BY account" 2>/dev/null || true)"
if [ -n "$running_rows" ] && [ "$running_rows" != "[]" ]; then
  echo "拒绝：台账里有 status='running' 的行，先停会话再清：" >&2
  printf '%s\n' "$running_rows" >&2
  exit 1
fi
alive_rows=""
while IFS='|' read -r acct pid; do
  [ -n "${pid:-}" ] || continue
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    alive_rows="${alive_rows}  ${acct} pid=${pid}"$'\n'
  fi
done < <(sqlite3 "$DB" "SELECT account,pid FROM accounts WHERE pid IS NOT NULL AND pid<>0 ORDER BY account" 2>/dev/null)
if [ -n "$alive_rows" ]; then
  echo "拒绝：台账里有 pid 仍活着的行，先停会话再清：" >&2
  printf '%s' "$alive_rows" >&2
  exit 1
fi

# ---- 选择器 ----------------------------------------------------------------
if [ "$ALL_STOPPED" = "1" ]; then
  WHERE="(status IS NULL OR status <> 'running')"
else
  esc="$(printf '%s' "$ACCOUNT_LIKE" | sed "s/'/''/g")"
  WHERE="account LIKE '$esc'"
fi

total_before="$(sqlite3 "$DB" "SELECT count(*) FROM accounts")"
matched="$(sqlite3 "$DB" "SELECT count(*) FROM accounts WHERE $WHERE")"
case "$total_before$matched" in
  ''|*[!0-9]*) echo "读台账失败（accounts 表不可读）" >&2; exit 1 ;;
esac

echo "匹配：$matched 行（清理前 accounts 总数 $total_before）"
if [ "$matched" = "0" ]; then
  echo "没有匹配行，什么都不做"
  exit 0
fi
echo "将删除的行（原文）："
sqlite3 -json "$DB" "SELECT * FROM accounts WHERE $WHERE ORDER BY account"

if [ "$APPLY" != "1" ]; then
  echo "dry-run：未删除任何行。确认后加 --apply 执行（会先备份）"
  exit 0
fi

# ---- 备份（WAL 安全） ------------------------------------------------------
BAK="${DB}.bak-$(date +%Y%m%d-%H%M%S)"
bak_esc="$(printf '%s' "$BAK" | sed "s/'/''/g")"
sqlite3 "$DB" ".backup '$bak_esc'" || { echo "备份失败，未删除任何行" >&2; exit 1; }
[ -s "$BAK" ] || { echo "备份文件为空，未删除任何行：$BAK" >&2; exit 1; }
echo "备份：$BAK"

# ---- 删除 ------------------------------------------------------------------
sqlite3 "$DB" "DELETE FROM accounts WHERE $WHERE" || { echo "删除失败；备份留在 $BAK" >&2; exit 1; }
total_after="$(sqlite3 "$DB" "SELECT count(*) FROM accounts")"
deleted=$((total_before - total_after))
echo "已删除：$deleted 行（清理后 accounts 总数 $total_after）"
echo "checks 历史保留（按账号仍可回查）"
exit 0
