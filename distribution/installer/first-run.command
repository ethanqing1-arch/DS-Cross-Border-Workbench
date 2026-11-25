#!/bin/bash
set +x
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

HERE="$(cd "$(dirname "$0")" && pwd -P)"
target="$HOME/kualang-workspace"
usage() { echo '用法：bash first-run.command [--target <独立工作区目录>]'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      shift
      [ "$#" -gt 0 ] && [ -n "$1" ] && [[ "$1" != -* ]] || { usage >&2; exit 2; }
      target="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

target="$(python3 - "$target" <<'PY'
import os
from pathlib import Path
import sys


def raise_walk_error(error):
    raise error


try:
    target = Path(sys.argv[1]).expanduser().resolve()
    for name in ("ds-bot-workspace", ".dsh"):
        default = Path.home().resolve() / name
        for protected in (default, default.resolve()):
            if target == protected or protected in target.parents or target in protected.parents:
                sys.exit("FAIL --target 必须与真实 DS Bot 工作区及 ~/.dsh 分开")
    if target.exists():
        if not target.is_dir():
            sys.exit("FAIL --target 必须是目录")
        for parent, dirs, files in os.walk(target, onerror=raise_walk_error):
            if any((Path(parent) / name).is_symlink() for name in dirs + files):
                sys.exit("FAIL 目标工作区含符号链接，请选择独立目录")
    print(target)
except (OSError, RuntimeError, ValueError) as error:
    sys.exit(f"FAIL 无法检查目标目录：{error}")
PY
)"

if [ -f "$HERE/../doctor.sh" ]; then
  dist="$(cd "$HERE/.." && pwd -P)"
else
  archives=("$HERE"/kualang-*.zip)
  if [ "${#archives[@]}" -ne 1 ] || [ ! -f "${archives[0]}" ]; then
    echo 'FAIL 请在 DMG 中保留唯一的 kualang-*.zip，或从解压包的 distribution/installer 运行' >&2
    exit 2
  fi
  dist="$(python3 - "${archives[0]}" "$target" <<'PY'
import errno
import hashlib
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


def verify_bundle(directory, manifest):
    if (directory / "MANIFEST.sha256").read_bytes() != manifest:
        raise ValueError("MANIFEST.sha256 与 ZIP 不一致")
    result = subprocess.run(["shasum", "-c", "MANIFEST.sha256"], cwd=directory, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        raise ValueError("MANIFEST.sha256 核验失败")


try:
    archive = Path(sys.argv[1])
    top = archive.stem
    if not re.fullmatch(r"kualang-[0-9]+\.[0-9]+\.[0-9]+", top):
        raise ValueError("发行 ZIP 文件名不符合版本约定")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    releases = Path(sys.argv[2]) / ".workbench-releases" / digest
    destination = releases / top
    with zipfile.ZipFile(archive) as package:
        names = set()
        for member in package.infolist():
            path = PurePosixPath(member.filename)
            mode = member.external_attr >> 16
            if (not path.parts or path.parts[0] != top or ".." in path.parts or
                    "\\" in member.filename or path in names or
                    stat.S_IFMT(mode) != (stat.S_IFDIR if member.is_dir() else stat.S_IFREG)):
                raise ValueError(f"ZIP 条目无效：{member.filename}")
            names.add(path)
        manifest = package.read(top + "/MANIFEST.sha256")
        if not destination.is_dir():
            releases.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".unpack-", dir=releases) as temp:
                package.extractall(temp)
                for member in package.infolist():
                    if not member.is_dir():
                        (Path(temp) / member.filename).chmod((member.external_attr >> 16) & 0o777)
                unpacked = Path(temp) / top
                verify_bundle(unpacked, manifest)
                try:
                    unpacked.rename(destination)
                except OSError as error:
                    if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not destination.is_dir():
                        raise
                    verify_bundle(destination, manifest)
        else:
            verify_bundle(destination, manifest)
    print(destination / "distribution")
except (KeyError, OSError, ValueError, zipfile.BadZipFile) as error:
    sys.exit(f"FAIL 解包：{error}")
PY
)"
fi

run_step() {
  local name="$1" status
  shift
  printf '\n== %s ==\n' "$name"
  "$@" || {
    status=$?
    printf 'FAIL %s（退出码 %s），见上方输出和 FIRST-RUN.md\n' "$name" "$status" >&2
    exit "$status"
  }
}

echo "目标工作区：$target"
run_step doctor /bin/bash "$dist/doctor.sh"
run_step install-all /bin/bash "$dist/install-all.sh" "$target"
run_step verify /bin/bash "$dist/verify.sh"

printf '\n== credentials ==\n'
python3 -B "$target/scripts/credential_check.py" ||
  echo '提示：凭证待配置或连通性待确认，安装已完成。'
if [ -z "${GATEWAY_TOKEN:-}" ] && [ -z "${DSH_SECRET_GATEWAY_TOKEN:-}" ]; then
  echo 'GATEWAY_TOKEN | 未配置'
  echo '提示：起网关前需要 GATEWAY_TOKEN。'
else
  echo 'GATEWAY_TOKEN | 已配置'
fi
printf '请在 DS Bot 的 Settings → Secrets 填写凭证，见 %s/docs/credentials-setup.md。\n' "${dist%/*}"
echo '填完后，在目标工作区运行 python3 scripts/credential_check.py 复核。'

printf '\n下一步做什么\n'
echo '  1. 按 docs/credentials-setup.md 填凭证并复核。'
echo '  2. 按 docs/release-checklist.md 的试装步骤跑首次取数。'
printf '  3. 在 %s 运行 python3 scripts/score_products.py，打开生成的打分表。\n' "$target"
