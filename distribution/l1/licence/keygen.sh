#!/usr/bin/env bash
# 生成 RSA-2048 私钥，并将公钥输出到 stdout。
set -eu

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo '用法：bash keygen.sh [仓库外的私钥路径]（默认 ~/dsh-ecom-licence/private.pem）'
  exit 0
fi
if [ "$#" -gt 1 ]; then
  echo 'FAIL 用法：bash keygen.sh [仓库外的私钥路径]' >&2
  exit 2
fi

exec python3 - "${1:-$HOME/dsh-ecom-licence/private.pem}" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile


try:
    requested = Path(sys.argv[1]).expanduser()
    private = requested.parent.resolve() / requested.name
    if any(os.path.lexists(parent / ".git") for parent in private.parents):
        sys.exit("FAIL 私钥路径必须在 Git 仓库外")
    if os.path.lexists(private):
        sys.exit("FAIL 私钥路径已存在：{}".format(private))

    os.umask(0o077)
    private.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".licence-key-", dir=private.parent) as temp:
        pending = Path(temp) / "private.pem"
        subprocess.run(
            ["/usr/bin/openssl", "genrsa", "-out", str(pending), "2048"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True,
        )
        pending.chmod(0o600)
        public = subprocess.check_output(
            ["/usr/bin/openssl", "rsa", "-in", str(pending), "-pubout"],
            stderr=subprocess.PIPE,
        )
        os.link(pending, private)  # Publish atomically without replacing an existing path.
    sys.stdout.buffer.write(public)
except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
    sys.exit("FAIL 生成密钥失败：{}".format(error))
PY
