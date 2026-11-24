#!/usr/bin/env bash
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
ROOT="$(cd "$SRC/.." && pwd -P)" || exit 2
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
finish() {
  echo "== 汇总: PASS=$PASS FAIL=$FAIL =="
  if [ "$FAIL" -eq 0 ]; then
    echo 'RESULT: READY'
    exit 0
  fi
  echo 'RESULT: NOT_READY'
  exit 1
}

tree_status() {
  if [ -e "$ROOT/.git" ]; then
    git --no-optional-locks -C "$ROOT" status --porcelain=v1 --untracked-files=all
  fi
}

umask 077
if ! before="$(tree_status)" || ! TMP="$(mktemp -d /tmp/kualang-licence-selftest.XXXXXX)"; then
  bad '无法读取 Git 状态或创建临时目录'
  finish
fi
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM

if ! cp -R "$SRC/l1" "$TMP/l1" ||
   ! bash "$TMP/l1/licence/keygen.sh" "$TMP/private.pem" > "$TMP/l1/licence/public.pem"; then
  bad '无法准备临时 L1 和测试密钥'
  finish
fi
export TMPDIR="$TMP" GATEWAY_URL=http://127.0.0.1:0

if ! python3 -B - "$TMP" <<'PY'
import base64
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import sys


temp = Path(sys.argv[1])
sys.path.insert(0, str(temp / "l1/licence"))
from verify import OPENSSL, canonical_payload, machine_id

now = datetime.now(timezone.utc)
licence = {
    "licensee": "Fixture A",
    "tier": "selftest",
    "machine_id": machine_id(),
    "issued_at": (now - timedelta(days=2)).isoformat(),
    "expires_at": (now + timedelta(days=1)).isoformat(),
}


def sign(name, payload):
    sig = subprocess.check_output(
        [OPENSSL, "dgst", "-sha256", "-sign", str(temp / "private.pem")],
        input=canonical_payload(payload),
    )
    path = temp / f"{name}.json"
    path.write_text(json.dumps(dict(payload, sig=base64.b64encode(sig).decode("ascii"))), encoding="utf-8")
    return path


valid = sign("valid", licence)
(temp / "tampered.json").write_bytes(valid.read_bytes().replace(b"Fixture A", b"Fixture B", 1))
sign("other-machine", dict(licence, machine_id=licence["machine_id"] + "-other"))
sign("expired", dict(licence, expires_at=(now - timedelta(days=1)).isoformat()))
PY
then
  bad '无法签发测试授权'
  finish
fi

expect_exit() {
  local label="$1" expected="$2" code="$3" out rc
  shift 3
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$expected" ] && printf '%s\n' "$out" | grep -Fq "$code"; then
    ok "${label}（退出码 ${rc}）"
  else
    bad "${label}（退出码 ${rc}，期望 ${expected}）"
    printf '%s\n' "$out"
  fi
}

VERIFY="$TMP/l1/licence/verify.py"
INSTALL="$TMP/l1/install.sh"
expect_exit '1. 合法 licence' 0 'PASS licence 校验通过' python3 "$VERIFY" --licence "$TMP/valid.json"
expect_exit '2. 改一个字节' 4 'E_LICENCE_SIGNATURE' python3 "$VERIFY" --licence "$TMP/tampered.json"
expect_exit '3. 错误机器码拦截 L1（FAIL E_LICENCE_MACHINE 授权绑定的机器码与本机不符）' \
  5 'FAIL E_LICENCE_MACHINE 授权绑定的机器码与本机不符' \
  bash "$INSTALL" "$TMP/blocked" --farm "$ROOT/farm" --require-licence --licence "$TMP/other-machine.json"
if [ -e "$TMP/blocked" ]; then bad '错误机器码拦截后仍创建了目标目录'; fi
expect_exit '4. 过期 licence' 6 'E_LICENCE_EXPIRED' python3 "$VERIFY" --licence "$TMP/expired.json"

default="$(bash "$INSTALL" "$TMP/default" --farm "$ROOT/farm" 2>&1)"; default_rc=$?
given="$(bash "$INSTALL" "$TMP/optional" --farm "$ROOT/farm" --licence "$TMP/absent.json" 2>&1)"; given_rc=$?
if [ "$default_rc" -eq 0 ] && [ "$given_rc" -eq 0 ] &&
   printf '%s\n' "$default" | grep -Fxq '== 汇总: write=1 skip=0 fail=0 ==' &&
   printf '%s\n' "$given" | grep -Fxq '== 汇总: write=1 skip=0 fail=0 =='; then
  ok '5. 默认安装及仅传 --licence 均照常安装（退出码 0 / 0）'
else
  bad "5. 默认安装或仅传 --licence 未保持基线（退出码 $default_rc / $given_rc）"
  printf '%s\n%s\n' "$default" "$given"
fi

if physical_tmp="$(cd "$TMP" && pwd -P)" && [[ "$physical_tmp/" != "$ROOT/"* ]] &&
   [ -s "$TMP/private.pem" ] && [ -s "$TMP/l1/licence/public.pem" ] &&
   after="$(tree_status)" && [ "$before" = "$after" ]; then
  ok '6. 临时密钥均在仓库外，Git 工作区状态前后一致（退出码 0）'
else
  bad '6. 临时密钥位置或 Git 工作区状态异常'
fi

finish
