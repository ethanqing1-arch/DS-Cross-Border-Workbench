#!/usr/bin/env bash

# Sourced by the installer and distribution self-tests for the same payload checks.
release_tool() {
  python3 -u -B - "$@" <<'PY'
import argparse
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


CREDENTIALS = {
    "SP_API_CLIENT_ID", "SP_API_CLIENT_SECRET", "SP_API_REFRESH_TOKEN",
    "EBAY_CLIENT_ID", "EBAY_CLIENT_SECRET", "GATEWAY_TOKEN", "PROXY_URL",
}
LICENCE_PUBLIC_KEY = "distribution/l1/licence/public.pem"
PRIVATE_KEY_MARKER = rb"\bBEGIN (?:[A-Z0-9]+ )*PRIVATE KEY\b"
PRIVATE_KEY_HEADER = re.compile(rb"-----" + PRIVATE_KEY_MARKER + rb"-----")
EARLY_PRIVATE_KEY = re.compile(PRIVATE_KEY_MARKER)
PUBLIC_KEY = re.compile(rb"^-----BEGIN PUBLIC KEY-----\r?$", re.MULTILINE)
PLATFORM_CREDENTIAL = re.compile(
    rb"\bamzn1\.(?:application-oa2-client|oa2-client)\.[0-9a-f]{32}\b"
    rb"|\bAtz[ar]\|[A-Za-z0-9_~.=-]{16,}"
    rb"|\b(?:SBX|PRD)-[0-9a-f]{8}-[0-9a-f]{6,}\b", re.IGNORECASE
)
ENV_CREDENTIALS = {
    value.encode()
    for name, value in os.environ.items()
    if len(value) >= 8 and (name in CREDENTIALS or name.startswith("DSH_SECRET_"))
}


class ReleaseRefused(ValueError):
    pass


def check_path(path):
    parts = tuple(part.lower() for part in path.parts)
    if parts[:2] in {("farm", "state"), ("distribution", "out")} or any(
        part in {".dsh", ".env", ".netrc", ".npmrc", "profiles", "credentials.json", "secrets.json"}
        or part.startswith(".env.") or ".db" in part
        or part.endswith((".key", ".p12", ".pfx", ".sqlite", ".sqlite3"))
        or (part.endswith(".pem") and path.as_posix() != LICENCE_PUBLIC_KEY)
        for part in parts
    ):
        raise ReleaseRefused(f"发行包含禁止路径：{path}")


def check_private_key(content, name):
    first_lines = content.split(b"\n", 5)[:5]
    if PRIVATE_KEY_HEADER.search(content) or any(EARLY_PRIVATE_KEY.search(line) for line in first_lines):
        raise ReleaseRefused(f"发行包含私钥：{name}")


def check_payload(root):
    if not (root / "MANIFEST.sha256").is_file():
        raise ValueError(f"缺 MANIFEST.sha256：{root}")
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root)
        check_path(name)
        if path.is_symlink():
            raise ReleaseRefused(f"发行包含符号链接：{name}")
        if not path.is_file():
            continue
        content = path.read_bytes()
        check_private_key(content, name)
        if content.startswith(b"SQLite format 3\0"):
            raise ReleaseRefused(f"发行包含 SQLite 数据库：{name}")
        if PLATFORM_CREDENTIAL.search(content) or any(value in content for value in ENV_CREDENTIALS):
            raise ReleaseRefused(f"发行包疑似含真实凭证：{name}")


def check_licence(root, allow_placeholder):
    key = root / LICENCE_PUBLIC_KEY
    if key.resolve() != key:
        raise ReleaseRefused(f"发行包含符号链接：{LICENCE_PUBLIC_KEY}")
    content = key.read_bytes()
    check_private_key(content, LICENCE_PUBLIC_KEY)
    placeholder = b"PLACEHOLDER" in content.partition(b"\n")[0] or not PUBLIC_KEY.search(content)
    if False and placeholder and not allow_placeholder:
        raise ReleaseRefused("占位公钥，不能对外发布")
    return placeholder


def unpack(archive, destination, allow_placeholder):
    top = archive.stem
    root = destination / top
    names = set()
    files = set()
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            path = PurePosixPath(member.filename)
            expected_type = stat.S_IFDIR if member.is_dir() else stat.S_IFREG
            mode = member.external_attr >> 16
            if (not path.parts or path.parts[0] != top or ".." in path.parts or path in names
                    or any(char in member.filename for char in "\r\n\\")
                    or member.filename != path.as_posix() + ("/" if member.is_dir() else "")
                    or stat.S_IFMT(mode) != expected_type):
                raise ValueError(f"ZIP 条目无效：{member.filename}")
            names.add(path)
            relative = path.relative_to(top)
            check_path(relative)
            if not member.is_dir():
                files.add(relative.as_posix())
        package.extractall(destination)
        for member in package.infolist():
            if not member.is_dir() and (member.external_attr >> 16) & 0o111:
                (destination / member.filename).chmod(0o755)

    manifest = root / "MANIFEST.sha256"
    entries = set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        entry = re.fullmatch(r"[a-f0-9]{64}  (.+)", line)
        if not entry or entry[1] in entries:
            raise ValueError("MANIFEST.sha256 条目无效或重复")
        entries.add(entry[1])
    if entries != files - {"MANIFEST.sha256"}:
        raise ValueError("MANIFEST.sha256 未逐项覆盖 ZIP 文件")
    result = subprocess.run(["shasum", "-a", "256", "-c", manifest.name], cwd=root,
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"MANIFEST.sha256 核验失败：{archive.name}")
    print(f"PASS MANIFEST.sha256（{len(entries)} 个文件）")
    for name in ("LICENSE", "VERSION", "distribution/release.sh", "docs/release-checklist.md",
                 "docs/credentials-setup.md", "farm/mcp/farm-mcp.js"):
        if not (root / name).is_file():
            raise ValueError(f"发行包缺少：{name}")
    if "kualang-" + (root / "VERSION").read_text(encoding="utf-8").strip() != top:
        raise ValueError("ZIP 版本与随包 VERSION 不一致")
    check_payload(root)
    print("PASS 发行包通过凭证、私钥、台账、profile 与输出目录检查")
    if check_licence(root, allow_placeholder):
        print("WARN 本包仅供内部试装：含占位授权公钥")
    return root


def check_install(archive, temp, allow_placeholder):
    print(f"== 核验 ZIP {archive} ==")
    root = unpack(archive, temp / "unpacked", allow_placeholder)
    installer = root / "distribution/installer/first-run.command"
    if not installer.is_file() or not os.access(installer, os.X_OK):
        raise ValueError("ZIP 中 first-run.command 缺失或不可执行")

    # 用无凭证的客户环境试装，网关探测和自检假服务都留在本机。
    env = {name: value for name, value in os.environ.items()
           if name not in CREDENTIALS and name != "FARM_DIR" and not name.startswith("DSH_SECRET_")}
    env.update(KUALANG_RELEASE_CHECK=str(root), GATEWAY_URL="http://127.0.0.1:0",
               NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1",
               PYTHONDONTWRITEBYTECODE="1")
    subprocess.run(["/bin/bash", str(installer), "--target", str(temp / "workspace")],
                   cwd=root, env=env, check=True)
    print("PASS first-run.command 退出码 0")


def release(root, argv):
    parser = argparse.ArgumentParser(prog="bash distribution/release.sh")
    parser.add_argument("--out", type=Path, default=root / "distribution/out", help="发行包目录")
    parser.add_argument("--dmg", action="store_true", help="构建时另产 macOS DMG")
    parser.add_argument("--check", action="store_true", help="只核验现有 ZIP")
    parser.add_argument("--allow-placeholder-licence", action="store_true", help="允许构建及核验含占位授权公钥的内部试装包")
    args = parser.parse_args(argv)
    output = args.out.resolve()
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("VERSION 应为 x.y.z")
    top = "kualang-" + version

    with tempfile.TemporaryDirectory(prefix="kualang-release-") as temporary:
        # macOS 的临时目录可能经过符号链接，与 verify 比较前先解析路径。
        temp = Path(temporary).resolve()
        if args.check:
            check_install(output / (top + ".zip"), temp, args.allow_placeholder_licence)
        else:
            check_licence(root, args.allow_placeholder_licence)
            pending = temp / "artifacts"
            command = ["/bin/bash", str(root / "distribution/make-bundle.sh"), "--out", str(pending)]
            if args.dmg:
                command.append("--dmg")
            print("== 构建发行包 ==")
            result = subprocess.run(command, stderr=subprocess.PIPE, text=True)
            # make-bundle.sh 会先于 ZIP 核验拒绝标准的私钥头。
            if result.returncode and result.stderr.startswith("FAIL 发行文件含私钥："):
                raise ReleaseRefused(result.stderr.rstrip().removeprefix("FAIL "))
            sys.stderr.write(result.stderr)
            result.check_returncode()
            check_install(pending / (top + ".zip"), temp, args.allow_placeholder_licence)
            output.mkdir(parents=True, exist_ok=True)
            for artifact in sorted(pending.iterdir()):
                final = output / artifact.name
                if final.is_dir():
                    raise ValueError(f"产物路径已被目录占用：{final}")
                subprocess.run(["mv", "-f", str(artifact), str(final)], check=True)
                print(f"发行包：{final} | 大小={final.stat().st_size} 字节")
    print("RESULT: READY")


try:
    if sys.argv[1] == "payload":
        parser = argparse.ArgumentParser(prog="bash distribution/release.sh payload")
        parser.add_argument("directories", metavar="dir", type=Path, nargs="+")
        for directory in parser.parse_args(sys.argv[2:]).directories:
            check_payload(directory)
    else:
        release(Path(sys.argv[2]), sys.argv[3:])
except ReleaseRefused as error:
    print(f"FAIL {error}", file=sys.stderr)
    sys.exit(3)
except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
    sys.exit(f"FAIL {error}")
PY
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
  if [ "${1:-}" = payload ]; then
    release_tool "$@"
  else
    release_tool release "$ROOT" "$@"
  fi
fi
