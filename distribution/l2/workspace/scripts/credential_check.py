#!/usr/bin/env python3
"""Check Amazon SP-API and eBay credentials without displaying their values."""

import argparse
import json
import sys

from credentials import EBAY_CREDENTIALS, SPAPI_CREDENTIALS, resolve_with_source
from ebay_fetch import ORIGINS, EbayClient, EbayError
from spapi_fetch import SPAPI, SPAPIError


class CheckParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, "参数无效。请用 --help 查看用法。\n")


def check_group(names, exchange):
    rows = []
    for name in names:
        value, source = resolve_with_source(name)
        rows.append({"name": name, "configured": bool(value), "source": source})

    reachable = False
    if all(row["configured"] for row in rows):
        try:
            exchange()
            reachable = True
        except (SPAPIError, EbayError, UnicodeError, OverflowError):
            pass

    for row in rows:
        if row["configured"]:
            row["connectivity"] = "reachable" if reachable else "unreachable"
        else:
            row["connectivity"] = "unconfigured"
    return rows


def main():
    parser = CheckParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--env", choices=ORIGINS, default="sandbox",
                        help="eBay 环境，默认 sandbox。Amazon 使用同一个 LWA 端点。")
    args = parser.parse_args()

    try:
        rows = check_group(SPAPI_CREDENTIALS.values(), lambda: SPAPI("US", None).access_token(
            None, retry_throttled=False,
        ))
        rows.extend(check_group(EBAY_CREDENTIALS, lambda: EbayClient(args.env, None).application_token(
            retry_throttled=False,
        )))

        if args.json:
            print(json.dumps({"credentials": rows}))
        else:
            connectivity = {"reachable": "可达", "unreachable": "不可达", "unconfigured": "未配置"}
            for row in rows:
                configured = "已配置" if row["configured"] else "未配置"
                source = "裸名" if row["source"] == "bare" else row["source"] or "—"
                print(f'{row["name"]} | {configured} | {source} | {connectivity[row["connectivity"]]}')
    except Exception:
        # Never pass exception text (which may contain request or response data) to the CLI.
        print("凭证自检执行失败。", file=sys.stderr)
        return 1
    return 0 if all(row["connectivity"] == "reachable" for row in rows) else 2


if __name__ == "__main__":
    sys.exit(main())
