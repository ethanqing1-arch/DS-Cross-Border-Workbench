#!/usr/bin/env python3
"""用系统 curl 从 AliExpress 美国区抓取搜索卡片。

  python3 fetch_aliexpress.py search "pet slow feeder" --limit 10
  python3 fetch_aliexpress.py search "pet slow feeder" --page 2 --csv --out ./out
  python3 fetch_aliexpress.py search "pet slow feeder" --no-cookie
  python3 fetch_aliexpress.py search "pet slow feeder" --html fixtures/aliexpress_us_trim.html
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import re
import subprocess
import sys
import time
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote

UA_POOL = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
]
REGION_COOKIE = "aep_usuc_f=site=glo&c_tp=USD&region=US&b_locale=en_US"
MAX_LIMIT = 60
MAX_PAGE = 3
ROW_FIELDS = (
    "item_id", "title", "sale_price_usd", "original_price_usd", "discount_pct",
    "sold_text", "sold_count", "rating",
)
INIT_DATA = re.compile(r"\bwindow\._dida_config_\._init_data_\s*=\s*\{\s*data\s*:\s*")
SOLD_COUNT = re.compile(
    r"(?:([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)|([0-9]+)(?:\.([0-9]{1,3}))?K)\+?\s+sold",
    re.IGNORECASE,
)


def fetch(url: str, with_cookie: bool) -> tuple[str, int]:
    """同一页最多请求三次。关闭 curlrc 和自动跳转，避免额外请求或会话配置。"""
    for attempt in range(3):
        cmd = [
            "curl", "-q", "-sS", "-m", "30", "--compressed",
            "-A", random.choice(UA_POOL),
            "-H", "accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "-H", "accept-language: en-US,en;q=0.9",
            "-w", "\n__HTTP__%{http_code}",
        ]
        if with_cookie:
            cmd.extend(["-H", f"cookie: {REGION_COOKIE}"])
        try:
            result = subprocess.run(
                [*cmd, url], capture_output=True, encoding="utf-8", errors="replace", timeout=45,
            )
        except subprocess.TimeoutExpired:
            body, code = "", 0
            print("curl 超时", file=sys.stderr)
        except OSError as exc:
            print(f"curl 无法启动：{exc}", file=sys.stderr)
            return "", 0
        else:
            marker = re.search(r"\n__HTTP__(\d{3})\s*$", result.stdout)
            body = result.stdout[:marker.start()] if marker else ""
            code = int(marker.group(1)) if marker else 0
            if result.returncode:
                print(result.stderr.strip(), file=sys.stderr)
                body, code = "", 0
            elif code == 200 and len(body) > 50_000:
                return body, code
        if attempt < 2:
            time.sleep(max(2.0, 1.5 * (attempt + 1) + random.random()))
    return body, code


class SearchPage(HTMLParser):
    def __init__(self, offline: bool):
        super().__init__()
        self.offline = offline
        self.lang = None
        self.seen_html = False
        self.data_tag = None
        self.initial_data = None

    def handle_starttag(self, tag, attrs):
        if tag == "html" and not self.seen_html:
            self.seen_html = True
            self.lang = dict(attrs).get("lang")
        if tag == "script" or (
            self.offline and tag == "template" and dict(attrs).get("id") == "aliexpress-search-data"
        ):
            self.data_tag = tag

    def handle_endtag(self, tag):
        if tag == self.data_tag:
            self.data_tag = None

    def handle_data(self, data):
        if self.data_tag and self.initial_data is None:
            match = INIT_DATA.search(data)
            if match:
                self.initial_data = data[match.end():]

    def search_fields(self) -> dict:
        if self.initial_data is None:
            return {}
        try:
            state, _ = json.JSONDecoder().raw_decode(self.initial_data)
        except ValueError:
            return {}
        return field(state, "data", "root", "fields") or {}


def field(value, *path):
    for key in path:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def text(value) -> str | None:
    return value if isinstance(value, str) and value.strip() else None


def usd_price(sale: dict, amount) -> float | None:
    displayed = text(field(sale, "formattedPrice"))
    currency = field(sale, "currencyCode")
    if not displayed or not re.match(r"US \$\s*[0-9]", displayed):
        return None
    if currency not in (None, "USD") or not re.fullmatch(r"[0-9]+", str(amount)):
        return None
    return round(int(amount) / 100, 2)


def sold_count(sold_text: str | None) -> int | None:
    match = SOLD_COUNT.fullmatch((sold_text or "").strip())
    if not match:
        return None
    whole, thousands, fraction = match.groups()
    if whole is not None:
        return int(whole.replace(",", ""))
    return int(thousands) * 1000 + int((fraction or "").ljust(3, "0"))


def parse_rows(items, limit: int) -> list[dict]:
    if not isinstance(items, list):
        return []
    rows = []
    for item in items[:limit]:
        sale = field(item, "prices", "salePrice")
        discount = field(sale, "discount")
        sold = text(field(item, "trade", "tradeDesc"))
        rows.append({
            "item_id": text(field(item, "productId")),
            "title": text(field(item, "title", "displayTitle")),
            "sale_price_usd": usd_price(sale, field(item, "trace", "utLogMap", "salePriceAmount")),
            "original_price_usd": None,
            "discount_pct": discount if type(discount) is int else None,
            "sold_text": sold,
            "sold_count": sold_count(sold),
            "rating": None,
        })
    return rows


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=ROW_FIELDS)
        writer.writeheader()
        for row in rows:
            price = row["sale_price_usd"]
            writer.writerow({**row, "sale_price_usd": f"{price:.2f}" if price is not None else None})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=["search"])
    parser.add_argument("keyword")
    parser.add_argument("--limit", type=int, default=MAX_LIMIT)
    parser.add_argument("--page", type=int, default=1, choices=range(1, MAX_PAGE + 1))
    parser.add_argument("--csv", action="store_true", help="另存 CSV，默认写到当前目录")
    parser.add_argument("--out", type=Path, help="写入 JSON 和可选 CSV 的目录")
    parser.add_argument("--html", type=Path, help="离线读取 HTML")
    parser.add_argument("--no-cookie", action="store_true", help="发送不带区域 cookie 的负例请求")
    args = parser.parse_args()
    slug = quote("-".join(args.keyword.split()), safe="")
    if not slug:
        parser.error("关键词不能为空")
    if not 1 <= args.limit <= MAX_LIMIT:
        parser.error(f"--limit 必须在 1 到 {MAX_LIMIT} 之间")

    url = f"https://www.aliexpress.com/w/wholesale-{slug}.html"
    if args.page > 1:
        url += f"?page={args.page}"

    degraded = []
    code = None
    offline = args.html is not None
    if offline:
        try:
            html = args.html.read_text(encoding="utf-8-sig")
        except (OSError, UnicodeError) as exc:
            print(f"无法读取 HTML：{exc}", file=sys.stderr)
            html = ""
            degraded.append("html_read_failed")
    else:
        html, code = fetch(url, with_cookie=not args.no_cookie)
        if code != 200:
            degraded.append(f"http_{code}")

    page = SearchPage(offline=offline)
    page.feed(html)
    page.close()
    if page.lang != "en":
        degraded.append("lang_not_en")
    if "US $" not in html:
        degraded.append("usd_price_marker_missing")
    if args.no_cookie:
        degraded.append("region_cookie_disabled")

    verified = not degraded
    rows = []
    exit_code = 1
    if verified:
        fields = page.search_fields()
        if args.page > 1 and str(field(fields, "pageInfo", "page")) != str(args.page):
            degraded.append("requested_page_not_verified")
        else:
            rows = parse_rows(field(fields, "mods", "itemList", "content"), args.limit)
            if rows:
                degraded.extend(key for key in ROW_FIELDS if any(row[key] is None for row in rows))
            else:
                degraded.append("no_cards")
            exit_code = 0

    payload = {
        "keyword": args.keyword, "url": url, "http": code, "lang": page.lang,
        "currency_verified": verified, "count": len(rows), "rows": rows, "degraded": degraded,
    }
    if exit_code == 0 and (args.out is not None or args.csv):
        out = args.out if args.out is not None else Path.cwd()
        try:
            out.mkdir(parents=True, exist_ok=True)
            if args.out is not None:
                (out / "aliexpress-search.json").write_text(
                    json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8",
                )
            if args.csv:
                write_csv(out / "aliexpress-search.csv", rows)
        except (OSError, csv.Error) as exc:
            print(f"无法写入结果：{exc}", file=sys.stderr)
            degraded.append("output_write_failed")
            exit_code = 1
    print(json.dumps(payload, ensure_ascii=False, indent=1))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
