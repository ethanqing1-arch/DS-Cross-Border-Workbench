#!/usr/bin/env python3
# =============================================================================
# ja3_compare.py — TLS 指纹（JA3/JA4 + HTTP2 Akamai）对照工具
#
# 目的：反检测浏览器可以伪造 JS 层的一切，但 TLS ClientHello 由内核的 BoringSSL
#       生成，改不了（除非真的改内核）。所以「UA 声称的 Chrome 版本」与
#       「实际 JA3/JA4」必须匹配，否则平台侧一眼识破。
#
# 用法：
#   pip install curl_cffi
#   python3 ja3_compare.py                      # 直连基线
#   python3 ja3_compare.py --proxy http://127.0.0.1:18080    # 经紫鸟环境出口
#   python3 ja3_compare.py --impersonate chrome124 --proxy ...
#
# 输出：tls.peet.ws 返回的 ja3_hash / ja4 / peetprint / http2 akamai 指纹，
#       以及与本机 curl_cffi 冒充版本的差异。
# =============================================================================
import argparse
import json
import sys

try:
    from curl_cffi import requests as creq
except ImportError:
    sys.exit("需要 curl_cffi: pip install curl_cffi")

ENDPOINT = "https://tls.peet.ws/api/all"


def probe(impersonate: str, proxy: str | None, tag: str) -> dict:
    proxies = {"http": proxy, "https": proxy} if proxy else None
    r = creq.get(ENDPOINT, impersonate=impersonate, proxies=proxies, timeout=30)
    d = r.json()
    tls = d.get("tls", {})
    http2 = d.get("http2", {})
    out = {
        "tag": tag,
        "impersonate": impersonate,
        "ja3": tls.get("ja3"),
        "ja3_hash": tls.get("ja3_hash"),
        "ja4": tls.get("ja4"),
        "peetprint_hash": tls.get("peetprint_hash"),
        "tls_version": tls.get("tls_version_negotiated"),
        "alpn": tls.get("alpn"),
        "cipher_suites": (tls.get("ciphers") or [])[:6],
        "extensions": (tls.get("extensions") or [])[:10],
        "akamai": http2.get("akamai_fingerprint"),
        "akamai_hash": http2.get("akamai_fingerprint_hash"),
        "user_agent": (d.get("http2", {}).get("sent_frames") or [{}])[0].get("headers", {}).get("user-agent")
        or d.get("user_agent"),
        "ip": d.get("ip"),
    }
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default=None, help="http://127.0.0.1:PORT 或 socks5://...")
    ap.add_argument("--impersonate", default="chrome", help="chrome / chrome124 / safari17_0 ...")
    ap.add_argument("--baseline", default="chrome", help="用于对照的本地冒充版本")
    a = ap.parse_args()

    rows = [probe(a.baseline, None, "direct-baseline")]
    if a.proxy:
        rows.append(probe(a.impersonate, a.proxy, "via-proxy"))

    print(json.dumps(rows, ensure_ascii=False, indent=2))

    if len(rows) == 2:
        b, t = rows
        print("\n=== 对照结论 ===")
        same_ja3 = b["ja3_hash"] == t["ja3_hash"]
        same_h2 = b["akamai_hash"] == t["akamai_hash"]
        print(f"JA3  一致: {same_ja3}   baseline={b['ja3_hash']}  target={t['ja3_hash']}")
        print(f"HTTP2 一致: {same_h2}   baseline={b['akamai_hash']}  target={t['akamai_hash']}")
        print(f"出口 IP : baseline={b['ip']}  target={t['ip']}")
        if not same_ja3:
            print("→ JA3 不同：目标侧 TLS 栈与宣称的浏览器版本不一致，或代理在该层做了终结。")


if __name__ == "__main__":
    main()
