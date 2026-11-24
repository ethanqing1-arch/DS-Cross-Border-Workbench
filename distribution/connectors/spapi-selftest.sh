#!/usr/bin/env bash
# Run the LWA, catalog and reports flow against an isolated loopback fixture.
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)" || exit 1

exec python3 - "$SRC" <<'PY'
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener


src = Path(sys.argv[1])
client = src.parent / "l2/workspace/scripts/spapi_fetch.py"
asin = "B0MOCK0001"
credentials = {
    "SP_API_CLIENT_ID": "mock-id",
    "SP_API_CLIENT_SECRET": "mock-secret",
    "SP_API_REFRESH_TOKEN": "mock-refresh",
}
fixture_values = (*credentials.values(), "mock-token", "denied-id")
opener = build_opener(ProxyHandler({}))
passed = 0
failed = 0


class TestFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise TestFailure(message)


def run_client(args, variables):
    env = dict(os.environ)
    for name in credentials:
        env.pop(name, None)
    env.update(variables)
    result = subprocess.run(
        [sys.executable, str(client), *args],
        env=env, capture_output=True, text=True, timeout=30,
    )
    require(all(value not in result.stdout and value not in result.stderr
                for value in fixture_values), "客户端输出含凭证值")
    return result


def check_error(result, status, expected):
    require(result.returncode == status, "客户端退出码不符")
    require(not result.stdout, "失败时 stdout 应为空")
    require(json.loads(result.stderr) == expected, "stderr 错误对象不符")


def check_output(result, path, kind, count):
    require(result.returncode == 0, "客户端执行失败")
    require(not result.stderr, "成功时 stderr 应为空")
    lines = result.stdout.splitlines()
    require(len(lines) == 1, "stdout 应只有一行摘要")
    require(json.loads(lines[0]) == {"type": kind, "items": count, "out": str(path)},
            "stdout 摘要不符")
    raw = path.read_text(encoding="utf-8")
    require(all(value not in raw for value in fixture_values), "输出文件含凭证值")
    return json.loads(raw), lines[0]


def check_missing(catalog_args):
    for name in credentials:
        partial = {key: value for key, value in credentials.items() if key != name}
        result = run_client(catalog_args, partial)
        check_error(result, 2, {"code": "E_SPAPI_CONFIG", "missing": [name]})


def check_catalog(catalog_args, out):
    path = out / f"catalog-{asin}-US.json"
    data, summary = check_output(run_client(catalog_args, credentials), path, "catalog", 1)
    require(data["asin"] == asin and data["summaries"][0]["marketplaceId"] == "ATVPDKIKX0DER",
            "目录结果缺少正确 ASIN 或 summaries")
    print(summary, flush=True)


def check_report(base_url, out):
    report_type = "GET_SALES_AND_TRAFFIC_REPORT"
    path = out / f"report-{report_type}-US-30d.json"
    result = run_client(
        ["report", "--type", report_type, "--days", "30", "--out", str(out), "--base-url", base_url],
        credentials,
    )
    data, summary = check_output(result, path, "report", 2)
    require(data["salesAndTrafficByDate"][0]["salesByDate"]["unitsOrdered"] == 2,
            "解压后缺少报告样例记录")
    print(summary, flush=True)


def read_stats(base_url):
    with opener.open(base_url + "/stats", timeout=5) as response:
        return json.load(response)


def check_counters(base_url):
    stats = read_stats(base_url)
    expected = {
        "signed_requests": 7, "lwa_requests": 2, "report_create_attempts": 2,
        "throttled": 1, "report_polls": 3, "in_progress": 2, "downloads": 1,
    }
    require(all(stats.get(key) == value for key, value in expected.items()),
            "服务端计数不符")
    return " ".join(f"{key}={stats[key]}" for key in expected)


def check_denied(base_url, catalog_args):
    result = run_client(catalog_args, {**credentials, "SP_API_CLIENT_ID": "denied-id"})
    check_error(result, 3, {"code": "E_SPAPI_AUTH", "status": 403})

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    signature = (
        f"AWS4-HMAC-SHA256 Credential=mock-id/{stamp[:8]}/us-east-1/execute-api/aws4_request, "
        f"SignedHeaders=host;x-amz-access-token;x-amz-date, Signature={'0' * 64}"
    )
    url = (base_url + f"/catalog/2022-04-01/items/{asin}"
           "?marketplaceIds=ATVPDKIKX0DER&includedData=summaries,attributes")
    for headers in (
        {"x-amz-date": stamp, "Authorization": signature},
        {"x-amz-date": stamp, "x-amz-access-token": "mock-token"},
    ):
        try:
            with opener.open(Request(url, headers=headers), timeout=5):
                raise TestFailure("缺认证头时假服务接受了请求")
        except HTTPError as error:
            with error:
                require(error.code == 403, "缺认证头时假服务未返回 403")
    require(read_stats(base_url).get("auth_rejections") == 3, "拒绝计数不符")


def check(label, function, *args):
    global passed, failed
    try:
        details = function(*args)
        suffix = f" {details}" if details else ""
        print(f"  PASS {label}{suffix}", flush=True)
        passed += 1
    except TestFailure as error:
        print(f"  FAIL {label}（{error}）", flush=True)
        failed += 1
    except (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.TimeoutExpired) as error:
        print(f"  FAIL {label}（{type(error).__name__}）", flush=True)
        failed += 1


def run_cases(server, port_file, out):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and server.poll() is None:
        try:
            port = int(port_file.read_text(encoding="ascii"))
            break
        except (OSError, ValueError):
            time.sleep(0.05)
    else:
        raise TestFailure("假服务未写入端口")
    base_url = f"http://127.0.0.1:{port}"
    catalog_args = ["catalog", "--asin", asin, "--marketplace", "US",
                    "--out", str(out), "--base-url", base_url]
    check("缺任一凭证仅点名变量（退出码 2）", check_missing, catalog_args)
    check("catalog 落盘且含 summaries", check_catalog, catalog_args, out)
    check("report 落盘且 gzip 解压得到 JSON", check_report, base_url, out)
    check("服务端计数（SigV4、LWA 缓存、429 重试、报告轮询与下载）",
          check_counters, base_url)
    check("403 映射 E_SPAPI_AUTH（退出码 3），缺签名或访问凭证时服务端拒绝",
          check_denied, base_url, catalog_args)


def stop(signum, _frame):
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGHUP, stop)
print("== SP-API 本地假服务自检 ==", flush=True)
with tempfile.TemporaryDirectory(prefix="dsh-spapi-", dir="/tmp") as root:
    port_file = Path(root) / "port"
    out = Path(root) / "out"
    mock_env = {name: value for name, value in os.environ.items() if name not in credentials}
    with subprocess.Popen([sys.executable, str(src / "spapi_mock.py"), "--port-file", str(port_file)],
                          env=mock_env) as server:
        try:
            run_cases(server, port_file, out)
        except TestFailure as error:
            print(f"  FAIL {error}", flush=True)
            failed += 1
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
print(f"== 汇总: PASS={passed} FAIL={failed} WARN=0 ==")
print("RESULT: READY" if failed == 0 else "RESULT: FAILED")
sys.exit(int(failed != 0))
PY
