#!/usr/bin/env bash
# Exercise the router with a loopback eBay fixture and local T3 commands.
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)" || exit 1

exec python3 - "$SRC" "$@" <<'PY'
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path


src = Path(sys.argv[1])
options = sys.argv[2:]
if options not in ([], ["--show-runs"]):
    sys.exit("用法：router-selftest.sh [--show-runs]")

router = src.parent / "l2/workspace/scripts/fetch_router.py"
credentials = {"EBAY_CLIENT_ID": "mock-id", "EBAY_CLIENT_SECRET": "mock-secret"}
fixture_values = (*credentials.values(), "mock-token")
clean_env = {key: value for key, value in os.environ.items()
             if key not in credentials and key != "GATEWAY_TOKEN" and not key.startswith("DSH_SECRET_")}
passed = failed = 0


class TestFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise TestFailure(message)


def check(label, test):
    global passed, failed
    try:
        test()
    except TestFailure as error:
        print(f"FAIL {label}（{error}）")
        failed += 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print(f"FAIL {label}（命令或产物格式错误）")
        failed += 1
    else:
        print(f"PASS {label}")
        passed += 1


def run(name, stub, *, variables=None, platform="ebay", manifest=None):
    out = root / name
    command = [sys.executable, str(router), "run", "--platform", platform, "--need", "search",
               "--q", "wireless earbuds", "--site", "EBAY_US", "--limit", "20",
               "--out", str(out), "--base-url", base,
               "--t3-cmd", shlex.join([sys.executable, str(stub)])]
    if manifest is not None:
        command += ["--manifest", str(manifest)]
    return subprocess.run(command, cwd=root, env={**clean_env, **(variables or {})},
                          capture_output=True, text=True, encoding="utf-8", timeout=30)


def check_success(child, name, tier):
    require(child.returncode == 0 and not child.stderr, "退出码或 stderr 不符")
    require(len(child.stdout.splitlines()) == 1, "stdout 应只有一行")
    path, = (root / name).glob("fetch_*.json")
    expected = {"tier_used": tier, "fallback": tier == "T3"}
    require(json.loads(child.stdout) == {**expected, "out": str(path)}, "stdout 摘要不符")
    data = json.loads(path.read_text(encoding="utf-8"))
    require(all(data[key] == value for key, value in expected.items()), "结果文件的 tier 或 fallback 不符")
    require(data["platform"] == "ebay" and data["need"] == "search"
            and data["args"] == {"q": "wireless earbuds", "site": "EBAY_US", "limit": 20},
            "结果文件的取数参数不符")
    return data


def check_t1():
    data = check_success(hit, "t1", "T1")
    require(len(data["result"]["itemSummaries"]) == 2, "假服务应返回两条商品")
    require(data["attempts"] == [
        {"tier": "T1", "connector": "ebay-api", "status": "ok", "exit_code": 0},
        {"tier": "T3", "connector": "browser-farm", "status": "skipped", "reason": "not_needed"},
    ] and not called.exists(), "T1 命中后应跳过 T3")


def check_fallback():
    data = check_success(fallback, "fallback", "T3")
    require(data["attempts"][0] == missing_credentials and data["attempts"][1]["status"] == "ok",
            "降级记录不符")
    require(data["result"] == {"items": [{"title": "T3 fixture"}]}, "T3 商品未写入结果文件")


def check_exhausted():
    require(exhausted.returncode == 7, "应以退出码 7 结束")
    require(json.loads(exhausted.stderr) == {"code": "E_NO_TIER", "attempts": [
        missing_credentials,
        {"tier": "T3", "connector": "browser-farm", "status": "failed", "reason": "error", "exit_code": 1},
    ]}, "错误码或降级记录不符")
    require(not (root / "exhausted").exists(), "失败时写出了结果目录")


def check_failed_stdout():
    require(config.returncode == 2 and json.loads(config.stderr)["code"] == "E_ROUTER_CONFIG",
            "缺 manifest 时应报 E_ROUTER_CONFIG")
    require(not exhausted.stdout and not config.stdout, "失败时 stdout 应为空")


def check_unimplemented():
    require(unsupported.returncode == 7 and not unsupported.stdout, "未实现的 T1 不应成功")
    require(json.loads(unsupported.stderr) == {"code": "E_NO_TIER", "attempts": [
        {"tier": "T1", "connector": "walmart-marketplace-api", "status": "skipped",
         "reason": "connector_not_implemented"},
        {"tier": "T3", "connector": "browser-farm", "status": "failed", "reason": "error", "exit_code": 1},
    ]}, "未实现的 T1 应标为跳过")


def check_credentials():
    output = [stream for child in (hit, fallback, exhausted, config, unsupported)
              for stream in (child.stdout, child.stderr)]
    output.extend(path.read_text(encoding="utf-8") for path in root.rglob("fetch_*.json"))
    require(all(value not in stream for value in fixture_values for stream in output), "输出含凭证值")


def wait_for_port(server, port_file):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and server.poll() is None:
        try:
            return int(port_file.read_text(encoding="ascii"))
        except (OSError, ValueError):
            time.sleep(0.05)
    raise TestFailure("假服务未写入端口")


print("== 降级链自检 ==", flush=True)
missing_credentials = {"tier": "T1", "connector": "ebay-api", "status": "skipped",
                       "reason": "E_EBAY_CONFIG", "exit_code": 2}
try:
    with tempfile.TemporaryDirectory(prefix="dsh-router-", dir="/tmp") as directory:
        root = Path(directory)
        called = root / "t3-called"
        ok_stub = root / "t3-ok.py"
        fail_stub = root / "t3-error.py"
        ok_stub.write_text('print(\'{"items": [{"title": "T3 fixture"}]}\')\n', encoding="utf-8")
        fail_stub.write_text(
            "import sys\nfrom pathlib import Path\n"
            "Path(__file__).with_name('t3-called').touch()\n"
            "print('T3 stub stdout')\nprint('T3 stub stderr', file=sys.stderr)\nsys.exit(1)\n",
            encoding="utf-8",
        )
        port_file = root / "port"
        with subprocess.Popen([sys.executable, str(src / "ebay_mock.py"), "--port-file", str(port_file)],
                              env=clean_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as server:
            try:
                base = f"http://127.0.0.1:{wait_for_port(server, port_file)}"
                hit = run("t1", fail_stub, variables=credentials)
                check("T1 命中，T3 跳过", check_t1)
                fallback = run("fallback", ok_stub)
                check("缺 eBay 凭证时降级到 T3", check_fallback)
                exhausted = run("exhausted", fail_stub)
                check("全 tier 失败返回 E_NO_TIER", check_exhausted)
                config = run("config", fail_stub, manifest=root / "missing.json")
                check("全 tier 失败与配置失败的 stdout 为空", check_failed_stdout)
                unsupported = run("unsupported", fail_stub, platform="walmart")
                check("未实现的 T1 标为 skipped", check_unimplemented)
                check("stdout、stderr 与结果文件无凭证", check_credentials)
                if options and not failed:
                    for label, child in (("T1 命中", hit), ("T3 降级", fallback), ("E_NO_TIER", exhausted)):
                        print(f"[{label}]\nstdout:\n{child.stdout}stderr:\n{child.stderr}exit={child.returncode}")
            finally:
                if server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
except (OSError, TestFailure, subprocess.SubprocessError):
    print("FAIL 无法启动假服务或运行路由")
    failed += 1

print(f"== 汇总: PASS={passed} FAIL={failed} WARN=0 ==")
print("RESULT: READY" if failed == 0 else "RESULT: FAILED")
sys.exit(int(failed != 0))
PY
