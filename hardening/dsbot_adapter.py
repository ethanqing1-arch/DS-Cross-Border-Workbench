#!/usr/bin/env python3
# =============================================================================
# dsbot_adapter.py — DS-Bot 的紫鸟最小适配层（仅 stdlib）
#
# 设计前提（已实测）：
#   1. CLI 失败时 **退出码仍为 0**，必须解析 JSON 的 ok 字段；
#   2. `browser start` 的输出是**流式 JSONL**（progress → 最终结果），不是单个 JSON；
#   3. 当前版本（6.50.2-latest.7）的 CLI **不接受** `--remote-debug-port`，
#      CDP 端口只能从内核进程命令行发现（--remote-debugging-port=N）。
#
# 用法：
#   python3 dsbot_adapter.py list
#   python3 dsbot_adapter.py start --id [STORE_ID] --mode agent
#   python3 dsbot_adapter.py ports            # 扫描运行中内核的 CDP 端口
#   python3 dsbot_adapter.py preflight --cdp http://127.0.0.1:[PORT]
#   python3 dsbot_adapter.py close --id [STORE_ID]
# =============================================================================
import argparse
import json
import urllib.request
import os
import re
import subprocess
import sys
import time

CLI = os.environ.get("ZINIAO_CLI", os.path.expanduser("~/.local/bin/ziniao"))
HARDENING = os.path.dirname(os.path.abspath(__file__))

# 失败分类：决定 DS-Bot 是否重试
NON_RETRYABLE = ("not logged in", "does not exist", "no permission", "invalid")
RETRYABLE = ("timeout", "not ready", "starting", "kernel", "download", "busy")


def run_jsonl(argv, timeout=180):
    """执行 CLI，逐行解析 JSONL，返回 (progress[], final)。退出码不可信，只看 ok。"""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    progress, final = [], None
    try:
        for line in p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("type") == "progress":
                progress.append(msg)
            else:
                final = msg
    finally:
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            final = {"ok": False, "error": "timeout"}
    if final is None:
        final = {"ok": False, "error": (p.stderr.read() or "no output").strip()[:400]}
    return progress, final


def classify(final):
    err = str(final.get("error", "")).lower()
    if any(k in err for k in NON_RETRYABLE):
        return "non_retryable"
    if any(k in err for k in RETRYABLE):
        return "retryable"
    return "unknown"


def cmd_list(_a):
    _, final = run_jsonl([CLI, "browser", "list", "--json"])
    if not final.get("ok"):
        print(json.dumps({"ok": False, "error": final.get("error"), "class": classify(final)}, ensure_ascii=False))
        return 2
    d = final.get("data") or {}
    items = d.get("items") if isinstance(d, dict) else (d or [])
    items = items or []
    print(json.dumps({"ok": True, "total": d.get("total", len(items)) if isinstance(d, dict) else len(items),
                      "count": len(items), "stores": items}, ensure_ascii=False, indent=2))
    return 0


def cmd_start(a):
    argv = [CLI, "browser", "start", "--id", str(a.id), "--mode", a.mode, "--json"]
    if a.headless:
        argv.append("--headless")
    if a.privacy:
        argv.append("--privacy")
    if a.url:
        argv += ["--url", a.url]

    t0 = time.monotonic()
    progress, final = run_jsonl(argv)
    elapsed = round(time.monotonic() - t0, 1)
    out = {
        "ok": bool(final.get("ok")),
        "elapsed_s": elapsed,
        "stages": [p.get("stage") for p in progress],
        "final": final,
    }
    if final.get("ok"):
        # 优先级：CLI 响应里的 data.debugPort（代码中 browser.start 直接返回）> ps 扫描
        d = final.get("data") or {}
        port = d.get("debugPort") or d.get("debug_port") or d.get("debuggPort")
        out["debugPort_from_cli"] = port
        ports = [int(port)] if port else discover_ports()
        out["cdp_ports"] = ports
        out["cdp"] = ("http://127.0.0.1:%d" % ports[0]) if ports else None
        if not ports:
            out["hint"] = ("CLI 未返回 debugPort 且 ps 未见 --remote-debugging-port："
                           "该环境未启用 CDP（检查 agent 模式/服务端下发），或改用 9481 zclaw 通道")
    else:
        out["class"] = classify(final)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if final.get("ok") else 3


def discover_ports():
    """扫描内核进程命令行里的 --remote-debugging-port=N。"""
    try:
        ps = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    ports = []
    for line in ps.splitlines():
        low = line.lower()
        # 只认紫鸟内核：命令行需含紫鸟可执行文件名或紫鸟数据目录，排除 ego/其他 Chromium
        if "ziniao" not in low and "ziniaobrowser" not in low:
            continue
        if line.lstrip().startswith(("ps ", "grep ")):
            continue
        m = re.search(r"--remote-debugging-port=(\d+)", line)
        if m:
            p = int(m.group(1))
            if p > 0 and p not in ports:
                ports.append(p)
    return ports


def cmd_health(_a):
    """zclaw 健康检查：无需登录即可读，作为 DS-Bot 的 readiness gate。"""
    url = "http://127.0.0.1:9481/health"
    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            d = json.loads(r.read().decode())
        print(json.dumps({"ok": True, "service": d.get("service"), "loggedIn": d.get("loggedIn"),
                          "hasApiKey": (d.get("status") or {}).get("hasApiKey"),
                          "runningStores": (d.get("status") or {}).get("runningStores"),
                          "toolsInvokeUrl": (d.get("status") or {}).get("toolsInvokeUrl")},
                         ensure_ascii=False, indent=2))
        return 0 if d.get("ok") else 3
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e), "hint": "GUI/daemon 未启动：ziniao start"}, ensure_ascii=False))
        return 4


def cmd_ports(_a):
    ports = discover_ports()
    out = {"ports": ports, "cdp": ["http://127.0.0.1:%d" % p for p in ports]}
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if ports else 4


def cmd_close(a):
    _, final = run_jsonl([CLI, "browser", "close", "--id", str(a.id), "--json"], timeout=60)
    print(json.dumps(final, ensure_ascii=False))
    return 0 if final.get("ok") else 3


def cmd_preflight(a):
    p = subprocess.run(["node", os.path.join(HARDENING, "preflight.js"), "--cdp", a.cdp, "--strict"],
                       capture_output=True, text=True, timeout=120)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    return p.returncode


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list").set_defaults(fn=cmd_list)
    sub.add_parser("ports").set_defaults(fn=cmd_ports)
    sub.add_parser("health").set_defaults(fn=cmd_health)

    s = sub.add_parser("start")
    s.add_argument("--id", required=True)
    s.add_argument("--mode", default="agent", choices=["normal", "agent"])
    s.add_argument("--headless", action="store_true")
    s.add_argument("--privacy", action="store_true")
    s.add_argument("--url")
    s.set_defaults(fn=cmd_start)

    c = sub.add_parser("close")
    c.add_argument("--id", required=True)
    c.set_defaults(fn=cmd_close)

    pf = sub.add_parser("preflight")
    pf.add_argument("--cdp", required=True)
    pf.set_defaults(fn=cmd_preflight)

    a = ap.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
