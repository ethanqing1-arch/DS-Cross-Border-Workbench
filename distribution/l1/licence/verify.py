#!/usr/bin/env python3
"""Verify a machine-bound licence locally using the system OpenSSL."""

import argparse
import base64
import binascii
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile


OPENSSL = "/usr/bin/openssl"
FIELDS = {"licensee", "tier", "machine_id", "issued_at", "expires_at", "sig"}


class LicenceError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code


def canonical_payload(document):
    payload = {key: value for key, value in document.items() if key != "sig"}
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def machine_id():
    try:
        system = platform.system()
        if system == "Darwin":
            result = subprocess.run(
                ["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                capture_output=True, text=True, check=True,
            )
            match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', result.stdout)
            if match:
                return match.group(1)
        elif system == "Linux":
            value = Path("/etc/machine-id").read_text(encoding="ascii").strip()
            if value:
                return value
    except (OSError, UnicodeError, subprocess.SubprocessError):
        pass
    raise LicenceError(3, "E_LICENCE_MACHINE", "无法读取本机机器码")


def timestamp(value):
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    result = datetime.fromisoformat(value)
    if result.tzinfo is None:
        raise ValueError("授权时间缺时区")
    return result


def unique_fields(pairs):
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError("授权字段重复")
    return fields


def openssl(*args, input=None):
    try:
        return subprocess.run([OPENSSL, *args], input=input, capture_output=True)
    except OSError as error:
        raise LicenceError(4, "E_LICENCE_SIGNATURE", "无法运行系统 openssl") from error


def verify(licence_path, public_key):
    try:
        raw = licence_path.read_bytes()
        key = public_key.read_bytes()
    except OSError as error:
        raise LicenceError(2, "E_LICENCE_FILE", "授权文件或公钥不可读") from error

    local_id = machine_id()
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_fields)
        if not isinstance(document, dict) or document.keys() != FIELDS or not all(
            isinstance(value, str) and value.strip() for value in document.values()
        ):
            raise ValueError("授权字段缺失或格式错误")
        signature = base64.b64decode(document["sig"], validate=True)
        timestamp(document["issued_at"])
        expires_at = timestamp(document["expires_at"])
    except (ValueError, binascii.Error, RecursionError) as error:
        raise LicenceError(4, "E_LICENCE_SIGNATURE", "授权文件格式错误") from error

    modulus = openssl("rsa", "-pubin", "-noout", "-modulus", input=key)
    if modulus.returncode or not re.fullmatch(rb"Modulus=[89A-Fa-f][0-9A-Fa-f]{511}", modulus.stdout.strip()):
        raise LicenceError(4, "E_LICENCE_SIGNATURE", "公钥须为 RSA-2048")

    try:
        with tempfile.TemporaryDirectory(prefix="dsh-licence-") as temp:
            key_file = Path(temp) / "public.pem"
            key_file.write_bytes(key)
            signature_file = Path(temp) / "signature"
            signature_file.write_bytes(signature)
            result = openssl(
                "dgst", "-sha256", "-verify", str(key_file), "-signature", str(signature_file),
                input=canonical_payload(document),
            )
    except OSError as error:
        raise LicenceError(4, "E_LICENCE_SIGNATURE", "无法准备验签文件") from error
    if result.returncode:
        raise LicenceError(4, "E_LICENCE_SIGNATURE", "签名校验失败")
    if document["machine_id"] != local_id:
        raise LicenceError(5, "E_LICENCE_MACHINE", "授权绑定的机器码与本机不符")
    if expires_at <= datetime.now(timezone.utc):
        raise LicenceError(6, "E_LICENCE_EXPIRED", "授权已过期")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--licence", type=Path, default=Path("licence.json"))
    parser.add_argument("--public-key", type=Path, default=Path(__file__).with_name("public.pem"))
    parser.add_argument("--print-machine-id", action="store_true")
    args = parser.parse_args()
    try:
        if args.print_machine_id:
            print(machine_id())
        else:
            verify(args.licence, args.public_key)
            print("PASS licence 校验通过")
    except LicenceError as error:
        print(f"FAIL {error.code} {error}", file=sys.stderr)
        return error.status
    return 0


if __name__ == "__main__":
    sys.exit(main())
