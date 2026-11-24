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
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile


ALLOW = ("LICENSE", "README.md", "CONTRIBUTING.md", "VERSION", "distribution", "farm", "docs")
WS = Path("farm/node_modules/ws")
CAPABILITY = Path("distribution/l1/capability/browser-farm.json")
PRIVATE = Path("farm/state")
PRIVATE_KEY = re.compile(rb"^-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----\r?$", re.MULTILINE)


def forbidden(path):
    return PRIVATE in (path, *path.parents) or path.suffix.lower() == ".key" or any(
        part in {".dsh", "profiles", "private.pem"} or ".db" in part for part in path.parts
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


def archive_file(tar, zip_archive, name, content, mode=0o644):
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = mode
    tar.addfile(info, io.BytesIO(content))
    entry = zipfile.ZipInfo(name)
    entry.create_system = 3  # Keep Unix executable bits when unzipped on macOS/Linux.
    entry.external_attr = (stat.S_IFREG | mode) << 16
    zip_archive.writestr(entry, content, compress_type=zipfile.ZIP_DEFLATED)


def archive_contents(root, top, files, tar_path, zip_path):
    manifest = []
    with tarfile.open(tar_path, "w:gz") as tar, zipfile.ZipFile(zip_path, "w") as zip_archive:
        directory = tarfile.TarInfo(top)
        directory.type = tarfile.DIRTYPE
        directory.mode = 0o755
        tar.addfile(directory)
        zip_directory = zipfile.ZipInfo(top + "/")
        zip_directory.create_system = 3
        zip_directory.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
        zip_archive.writestr(zip_directory, b"")

        for relative in files:
            source = root / relative
            if source.resolve() != source or not source.is_file():
                raise ValueError("发行文件缺失或经过符号链接：{}".format(relative))
            name = relative.as_posix()
            if any(char in name for char in "\r\n\\"):
                raise ValueError("文件名无法写入 MANIFEST.sha256：{!r}".format(name))
            content = source.read_bytes()
            if PRIVATE_KEY.search(content):
                raise ValueError("发行文件含私钥：{}".format(relative))
            if relative == CAPABILITY:
                capability = json.loads(content)
                if capability["env"]["GATEWAY_TOKEN"] != "$DSH_SECRET_GATEWAY_TOKEN":
                    raise ValueError("capability 里的令牌必须是占位符")
                capability["command"] = "$NODE_BIN"
                capability["args"][0] = "$FARM_MCP_PATH"
                content = (json.dumps(capability, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
            archive_file(tar, zip_archive, top + "/" + name, content, mode)
            manifest.append("{}  {}\n".format(hashlib.sha256(content).hexdigest(), name))
        archive_file(tar, zip_archive, top + "/MANIFEST.sha256", "".join(manifest).encode("utf-8"))

    with tarfile.open(tar_path, "r:gz") as tar, zipfile.ZipFile(zip_path) as zip_archive:
        tar_names = tar.getnames()
        if tar_names != [name.rstrip("/") for name in zip_archive.namelist()]:
            raise ValueError("tar.gz 和 zip 的发行清单不一致")
        for name in tar_names:
            path = Path(name)
            if not path.parts or path.parts[0] != top or excluded(Path(*path.parts[1:])):
                raise ValueError("发行包自查命中禁止路径：{}".format(name))
    return len(manifest) + 1


def make_dmg(tool, installer, zip_path, dmg_path):
    source = dmg_path.parent / "image"
    source.mkdir()
    shutil.copy2(zip_path, source)
    shutil.copy2(installer / "FIRST-RUN.md", source)
    shutil.copy2(installer / "first-run.command", source / "install.command")
    subprocess.run(
        [tool, "create", "-quiet", "-srcfolder", str(source), "-volname", "Cross-Border Workbench",
         "-format", "UDZO", str(dmg_path)],
        check=True,
    )


def build(root, output, with_dmg):
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
    with tempfile.TemporaryDirectory(prefix=".bundle-", dir=output) as temp:
        staging = Path(temp)
        tar_path = staging / (top + ".tar.gz")
        zip_path = staging / (top + ".zip")
        count = archive_contents(root, top, files, tar_path, zip_path)
        artifacts = [tar_path, zip_path]
        if with_dmg:
            tool = shutil.which("hdiutil")
            if tool:
                dmg_path = staging / (top + ".dmg")
                make_dmg(tool, root / "distribution/installer", zip_path, dmg_path)
                artifacts.append(dmg_path)
            else:
                print("WARN 找不到 hdiutil，跳过 DMG")

        for pending in artifacts:
            checksum = hashlib.sha256(pending.read_bytes()).hexdigest()
            size = pending.stat().st_size
            final = pending.replace(output / pending.name)
            print("发行包：{} | 大小={} 字节 | SHA256={}".format(final, size, checksum))

    print("文件数={}（含 MANIFEST.sha256）".format(count))


root = Path(sys.argv[1])
parser = argparse.ArgumentParser(prog="bash distribution/make-bundle.sh")
parser.add_argument("--out", type=Path, default=root / "distribution/out", help="发行包输出目录")
parser.add_argument("--dmg", action="store_true", help="另产 macOS DMG（需要 hdiutil）")
args = parser.parse_args(sys.argv[2:])
try:
    build(root, args.out.resolve(), args.dmg)
except (KeyError, IndexError, OSError, ValueError, subprocess.CalledProcessError,
        tarfile.TarError, zipfile.BadZipFile) as error:
    sys.exit("FAIL {}".format(error))
PY
