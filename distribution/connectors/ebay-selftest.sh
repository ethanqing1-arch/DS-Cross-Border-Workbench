#!/usr/bin/env bash
# Run the eBay client against an isolated loopback fixture.
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)" || exit 1

exec python3 - "$SRC" <<'PY'
import base64
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener


src = Path(sys.argv[1])
client = src.parent / "l2/workspace/scripts/ebay_fetch.py"
credentials = {"EBAY_CLIENT_ID": "mock-id", "EBAY_CLIENT_SECRET": "mock-secret"}
wrong_secret = "invalid-test-secret"
fixture_values = (*credentials.values(), "mock-token", wrong_secret,
                  base64.b64encode(b"mock-id:mock-secret").decode("ascii"))
credential_names = set(credentials) | {"DSH_SECRET_" + name for name in credentials}
clean_env = {name: value for name, value in os.environ.items() if name not in credential_names}
opener = build_opener(ProxyHandler({}))
passed = failed = 0


class TestFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise TestFailure(message)


def run_client(base, args, variables):
    result = subprocess.run(
        [sys.executable, str(client), *args, "--base-url", base],
        env={**clean_env, **variables}, capture_output=True, text=True, timeout=30,
    )
    require(all(value not in result.stdout and value not in result.stderr for value in fixture_values),
            "客户端输出含凭证值")
    return result


def check_error(result, status, expected):
    require(result.returncode == status and not result.stdout, "退出码或 stdout 不符")
    require(json.loads(result.stderr) == expected, "stderr 错误对象不符")


def check_success(result):
    require(result.returncode == 0 and not result.stderr, "客户端执行失败或写入 stderr")
    require(len(result.stdout.splitlines()) == 1, "stdout 应只有一行")
    return json.loads(result.stdout)


def stats(base):
    with opener.open(base + "/_stats", timeout=5) as response:
        return json.load(response)


def check_missing(base):
    for name in credentials:
        partial = {key: value for key, value in credentials.items() if key != name}
        check_error(run_client(base, ["token"], partial), 2,
                    {"code": "E_EBAY_CONFIG", "missing": [name]})
    check_error(run_client(base, ["token"], {}), 2,
                {"code": "E_EBAY_CONFIG", "missing": list(credentials)})
    require(stats(base)["token_requests"] == 0, "缺凭证时发出了 HTTP 请求")


def check_token(base):
    result = run_client(base, ["token", "--env", "sandbox"], credentials)
    require(check_success(result) == {"expires_in": 3600}, "有效期不符")
    counters = stats(base)
    require(counters["token_requests"] >= 1 and counters["last_basic_ok"] is True,
            "假服务未验证 Basic 认证")
    print(result.stdout, end="", flush=True)
    return "/_stats " + json.dumps(counters, sort_keys=True)


def check_search(base, out):
    before = stats(base)
    result = run_client(base, ["search", "--q", "wireless earbuds", "--site", "EBAY_US",
                               "--limit", "20", "--out", str(out)], credentials)
    summary = check_success(result)
    counters = stats(base)
    require(counters["throttled_count"] >= 1 and counters["browse_requests"] >= 2
            and counters["last_marketplace"] == "EBAY_US", "限流次数、重试次数或站点不符")
    require(counters["token_requests"] == before["token_requests"] + 1
            and counters["last_basic_ok"] is True, "search 进程未复用应用令牌")
    files = list(out.glob("ebay_search_*.json"))
    require(len(files) == 1 and files[0].stat().st_size > 0, "结果文件缺失、为空或有多个")
    require(summary == {"items": 2, "out": str(files[0])}, "stdout 摘要不符")
    raw = files[0].read_text(encoding="utf-8")
    require(all(value not in raw for value in fixture_values), "结果文件含凭证值")
    items = json.loads(raw)["itemSummaries"]
    require([item["itemId"] for item in items] == ["v1|10001|0", "v1|10002|0"],
            "结果缺少两条预期的 itemId")
    require(items[0]["title"] == "Wireless Earbuds"
            and items[0]["price"] == {"value": "29.99", "currency": "USD"}, "标题或价格不符")
    print(result.stdout, end="", flush=True)
    return "/_stats " + json.dumps(counters, sort_keys=True)


def check_bad_secret(base):
    result = run_client(base, ["token"], {**credentials, "EBAY_CLIENT_SECRET": wrong_secret})
    check_error(result, 3, {"code": "E_EBAY_AUTH", "status": 401})
    counters = stats(base)
    require(counters["last_basic_ok"] is False, "假服务接受了错误密钥")
    return "/_stats " + json.dumps(counters, sort_keys=True)


def check_browse_headers(base):
    url = base + "/buy/browse/v1/item_summary/search?q=earbuds&limit=20"
    for headers in ({"X-EBAY-C-MARKETPLACE-ID": "EBAY_US"}, {"Authorization": "Bearer mock-token"}):
        try:
            with opener.open(Request(url, headers=headers), timeout=5):
                raise TestFailure("缺认证头或站点头时假服务仍接受请求")
        except HTTPError as error:
            with error:
                require(error.code == 401 and bool(json.load(error)["errors"]),
                        "假服务未返回 eBay 风格的 401 错误")


def check(label, function, *args):
    global passed, failed
    try:
        details = function(*args)
        print(f"  PASS {label}" + (f" {details}" if details else ""), flush=True)
        passed += 1
    except TestFailure as error:
        print(f"  FAIL {label}（{error}）", flush=True)
        failed += 1
    except (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.TimeoutExpired) as error:
        print(f"  FAIL {label}（{type(error).__name__}）", flush=True)
        failed += 1


def wait_for_port(server, port_file):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and server.poll() is None:
        try:
            return int(port_file.read_text(encoding="ascii"))
        except (OSError, ValueError):
            time.sleep(0.05)
    raise TestFailure("假服务未写入端口")


def stop(signum, _frame):
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGHUP, stop)
print("== eBay 本地假服务自检 ==", flush=True)
with tempfile.TemporaryDirectory(prefix="dsh-ebay-", dir="/tmp") as root:
    port_file = Path(root) / "port"
    with subprocess.Popen([sys.executable, str(src / "ebay_mock.py"), "--port-file", str(port_file)],
                          env=clean_env) as server:
        try:
            base = f"http://127.0.0.1:{wait_for_port(server, port_file)}"
            check("缺凭证仅点名变量（退出码 2）", check_missing, base)
            check("token 通过 Basic 认证", check_token, base)
            check("search 经过 429 重试，复用令牌并写出两条商品", check_search, base, Path(root) / "out")
            check("错误密钥返回 401，映射 E_EBAY_AUTH（退出码 3）", check_bad_secret, base)
            check("Browse 缺 Bearer 或 marketplace 头时返回 401", check_browse_headers, base)
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
