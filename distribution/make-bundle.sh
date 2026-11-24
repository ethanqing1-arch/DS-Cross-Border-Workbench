#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
exec python3 - "$ROOT" "$@" <<'PY'
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile


ALLOW = ("LICENSE", "README.md", "CONTRIBUTING.md", "VERSION", "distribution", "farm", "docs")
WS = Path("farm/node_modules/ws")
CAPABILITY = Path("distribution/l1/capability/browser-farm.json")
PRIVATE = (Path("farm/state"), Path("farm/profiles"))


def forbidden(path):
    return any(".db" in part for part in path.parts) or any(
        path == directory or directory in path.parents for directory in PRIVATE
    )


def excluded(path):
    return forbidden(path) or any(
        part in {".git", ".DS_Store", ".env", "__pycache__"} or part.startswith(".env.")
        for part in path.parts
    ) or Path("distribution/out") in (path, *path.parents)


def walk(root, relative):
    if excluded(relative):
        return
    source = root / relative
    if source.is_symlink():
        raise ValueError("不支持符号链接：{}".format(relative))
    if source.is_dir():
        for child in sorted(source.iterdir()):
            yield from walk(root, relative / child.name)
    else:
        yield relative


def bundle_files(root):
    if (root / ".git").exists():
        # 只取已纳入版本控制的工作树文件，避免把本地草稿和运行产物发出去。
        tracked = subprocess.check_output(["git", "ls-files", "--cached", "-z", "--", *ALLOW], cwd=root)
        yield from (Path(os.fsdecode(name)) for name in tracked.split(b"\0") if name)
        yield from walk(root, WS)
    else:
        for entry in ALLOW:
            yield from walk(root, Path(entry))


def archive_file(archive, name, content, mode=0o644):
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = mode
    archive.addfile(info, io.BytesIO(content))


def build(root, output):
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("VERSION 应为 x.y.z")
    top = "dsh-ecom-" + version
    if not (root / WS / "package.json").is_file():
        raise ValueError("缺 farm/node_modules/ws，请先在 farm/ 运行 npm install")

    files = sorted({path for path in bundle_files(root) if not excluded(path)})
    if CAPABILITY not in files or WS / "package.json" not in files:
        raise ValueError("载荷或 ws 未进入发行清单")

    output.mkdir(parents=True, exist_ok=True)
    final = output / (top + ".tar.gz")
    with tempfile.TemporaryDirectory(prefix=".bundle-", dir=output) as temp:
        pending = Path(temp) / final.name
        manifest = []
        with tarfile.open(pending, "w:gz") as archive:
            directory = tarfile.TarInfo(top)
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            archive.addfile(directory)
            for relative in files:
                source = root / relative
                if source.resolve() != source or not source.is_file():
                    raise ValueError("发行文件缺失或经过符号链接：{}".format(relative))
                name = relative.as_posix()
                if any(char in name for char in "\r\n\\"):
                    raise ValueError("文件名无法写入 MANIFEST.sha256：{!r}".format(name))
                content = source.read_bytes()
                if relative == CAPABILITY:
                    capability = json.loads(content)
                    if capability["env"]["GATEWAY_TOKEN"] != "$DSH_SECRET_GATEWAY_TOKEN":
                        raise ValueError("capability 里的令牌必须是占位符")
                    capability["command"] = "$NODE_BIN"
                    capability["args"][0] = "$FARM_MCP_PATH"
                    content = (json.dumps(capability, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
                mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
                archive_file(archive, top + "/" + name, content, mode)
                manifest.append("{}  {}\n".format(hashlib.sha256(content).hexdigest(), name))
            archive_file(archive, top + "/MANIFEST.sha256", "".join(manifest).encode("utf-8"))

        with tarfile.open(pending, "r:gz") as archive:
            for member in archive:
                path = Path(member.name)
                if not path.parts or path.parts[0] != top or forbidden(Path(*path.parts[1:])):
                    raise ValueError("发行包自查命中禁止路径：{}".format(member.name))
        checksum = hashlib.sha256(pending.read_bytes()).hexdigest()
        size = pending.stat().st_size
        pending.replace(final)

    print("发行包：{}".format(final))
    print("SHA256={}".format(checksum))
    print("大小={} 字节".format(size))
    print("文件数={}（含 MANIFEST.sha256）".format(len(manifest) + 1))


root = Path(sys.argv[1])
parser = argparse.ArgumentParser(prog="bash distribution/make-bundle.sh")
parser.add_argument("--out", type=Path, default=root / "distribution/out", help="发行包输出目录")
args = parser.parse_args(sys.argv[2:])
try:
    build(root, args.out.resolve())
except (KeyError, IndexError, OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
    sys.exit("FAIL {}".format(error))
PY
