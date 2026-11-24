#!/usr/bin/env python3
"""
免费 Amazon 调研抓取器（零依赖：只用标准库 + 系统 curl）

设计依据（2026-11-22 实测）：
  curl + 正常 UA + i18n-prefs=USD  → 200，48 张卡片，四字段齐全
  内置网页抓取器 / read_url        → 503（指纹被拦）
  Playwright + 本机 Chrome         → 200，能渲染，但评论原文仍需登录

所以：HTTP 为主，Playwright 只在需要交互时另走 supplement.mjs。
拿不到就返回 null + degraded，绝不编数字。

用法：
  python3 fetch_amazon.py search "pet slow feeder" --limit 20
  python3 fetch_amazon.py product B0C5HSCS8J
  python3 fetch_amazon.py product --asin-file asins.txt --output amazon-candidates.csv
  python3 fetch_amazon.py search "dog bowl" --limit 30 --csv
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys, time, random, csv, io
from datetime import datetime
from html import unescape
from pathlib import Path

UA_POOL = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
]
COOKIE = "i18n-prefs=USD; lc-main=en_US"
UNAVAILABLE_REVIEW_FIELDS = ("rating_histogram", "customers_say", "review_text")
MAX_BATCH_SIZE = 20
NEED_INPUT = "NEED_INPUT"
BATCH_FIELDS = (
    "asin", "品类", "商品名", "预估售价", "头部评论数", "月搜索量", "在售竞品数",
    "1688进价", "运费", "平均退货率", "推广费率", "供应稳定性分",
    "上架时间", "卖家", "发货方式", "bsr", "评分", "抓取时间",
)


def fetch(url: str, retries: int = 2) -> tuple[str, int]:
    """用 curl 取 HTML（已验证可用，urllib/内置抓取器会被 503）"""
    last = ""
    for i in range(retries + 1):
        cmd = [
            "curl", "-sS", "-L", "-m", "30", "--compressed",
            "-A", random.choice(UA_POOL),
            "-H", "accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "-H", "accept-language: en-US,en;q=0.9",
            "-H", f"cookie: {COOKIE}",
            "-w", "\n__HTTP__%{http_code}",
            url,
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=45).stdout
        except subprocess.TimeoutExpired:
            out = ""
        m = re.search(r"\n__HTTP__(\d{3})\s*$", out)
        code = int(m.group(1)) if m else 0
        body = out[: m.start()] if m else out
        if code == 200 and len(body) > 50_000:
            return body, code
        last = body
        if i < retries:
            time.sleep(max(2.0, 1.5 * (i + 1) + random.random()))
    return last, code


def _blocked(html: str, code: int) -> str | None:
    if code != 200:
        return f"http_{code}"
    if re.search(r"Sorry! Something went wrong|Enter the characters you see|api-services-support@amazon", html):
        return "blocked_by_amazon"
    return None


def parse_search(html: str, limit: int) -> list[dict]:
    starts = [
        (m.group(1), m.end())
        for m in re.finditer(
            r'data-asin="([A-Z0-9]{10})"[^>]{0,400}?data-component-type="s-search-result"', html
        )
    ]
    rows = []
    for i, (asin, pos) in enumerate(starts[:limit]):
        end = starts[i + 1][1] if i + 1 < len(starts) else pos + 60_000
        blk = html[pos:end]
        price = re.search(r'a-offscreen">\s*([^<]{1,14})\s*<', blk)
        rating = re.search(r'aria-label="([\d.]+) out of 5 stars', blk)
        rev = re.search(r'aria-label="([\d,]+) ratings?"', blk) or re.search(
            r's-underline-text">\s*\(?([\d,.\sKM+]+)\)?\s*<', blk
        )
        title = re.search(r'<h2[^>]*>[^<]*<span[^>]*>([^<]{5,120})</span>', blk, re.S)
        rows.append({
            "asin": asin,
            "title": (title.group(1).strip() if title else None),
            "price": (price.group(1).strip() if price else None),
            "rating": (float(rating.group(1)) if rating else None),
            "reviews": (rev.group(1).strip() if rev else None),
            "sponsored": bool(re.search(r'>\s*Sponsored\s*<', blk)),
        })
    return rows


def parse_product(html: str, asin: str) -> dict:
    def one(pat, flags=0, grp=1):
        m = re.search(pat, html, flags)
        return m.group(grp).strip() if m else None

    def display_text(raw):
        text = unescape(re.sub(r"<[^>]+>", "", raw or ""))
        return " ".join(text.replace("\u200e", "").replace("\u200f", "").split()) or None

    def offer_text(label):
        # 只取对应标签后紧邻的 offer-display-feature-text，避免串到其他报价或弹层。
        value = one(
            rf'<span\b[^>]*>\s*{re.escape(label)}\s*</span>\s*(?:</div>\s*)*'
            r'<div\b[^>]*\bclass=["\'][^"\']*\boffer-display-feature-text(?=\s|["\'])[^"\']*["\'][^>]*>\s*'
            r'(?:<div\b[^>]*>\s*)?<(?:a|span)\b[^>]*\bclass=["\'][^"\']*'
            r'\boffer-display-feature-text-message(?=\s|["\'])[^"\']*["\'][^>]*>([^<]*)'
        )
        return display_text(value)

    date_item = display_text(one(
        r'<li\b[^>]*>\s*(?:<span\b[^>]*>\s*){0,2}(Date First Available\b.*?)</li>', re.S
    ))
    date_first_available = (date_item or "").partition(":")[2].strip() or None
    sold_by = offer_text("Sold by")
    ships_from = offer_text("Ships from")
    fulfillment = "unknown"
    if ships_from:
        fulfillment = "fba" if "amazon" in ships_from.casefold() else "fbm"
    new_fields = {
        "date_first_available": date_first_available,
        "sold_by": sold_by,
        "ships_from": ships_from,
        "fulfillment": fulfillment,
    }
    degraded = [field for field, value in new_fields.items() if value is None]
    degraded.extend(UNAVAILABLE_REVIEW_FIELDS)

    price = one(r'class="a-offscreen">\s*([^<]{1,14})\s*<')
    rating = one(r'id="acrPopover"[^>]*title="([\d.]+) out of 5') or one(
        r'([\d.]+) out of 5 stars'
    )
    reviews = one(r'id="acrCustomerReviewText"[^>]*>\s*([\d,]+)') or one(
        r'([\d,]+)\s+global ratings'
    )
    # BSR：去重保序（同一行常被重复匹配）
    bsr_all, seen = [], set()
    for rank, cat in re.findall(r"#([\d,]+)\s+in\s+([A-Za-z][A-Za-z &,'-]{2,50})", html):
        key = (rank, cat.strip())
        if key not in seen:
            seen.add(key)
            bsr_all.append(key)
    # 五点：限定在 #feature-bullets 区块内，避免抓到退货政策/变体名
    m = re.search(r'id="feature-bullets"', html)
    frame = html[m.end(): m.end() + 24000] if m else ""
    raw = re.findall(
        r'<li[^>]*>\s*<span[^>]*class="[^"]*a-list-item[^"]*"[^>]*>(.*?)</span>\s*</li>', frame, re.S
    )
    bullets = [
        re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", b)).strip()
        for b in raw
        if 15 < len(b) < 600
    ][:6]
    title = one(r'id="productTitle"[^>]*>\s*([^<]{5,220})')
    return {
        "asin": asin,
        "title": title.strip() if title else None,
        "price": price,
        "rating": float(rating) if rating else None,
        "reviews": reviews,
        "bsr": [f"#{r} in {c.strip()}" for r, c in bsr_all[:3]],
        "bullets": [b.strip()[:200] for b in bullets],
        **new_fields,
        "degraded": degraded,
    }


def fetch_product(asin: str) -> dict:
    html, code = fetch(f"https://www.amazon.com/dp/{asin}")
    bad = _blocked(html, code)
    if bad:
        return {"error": bad, **parse_product("", asin)}
    return parse_product(html, asin)


def load_asins(path: Path) -> list[str]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        rows = [row for row in csv.reader(f) if any(cell.strip() for cell in row)]
    if not rows:
        raise ValueError("ASIN 文件没有数据")

    header = [cell.strip().lower() for cell in rows[0]]
    if "asin" in header:
        column = header.index("asin")
        ids = [row[column].strip() if column < len(row) else "" for row in rows[1:]]
    elif all(len(row) == 1 for row in rows):
        ids = [row[0].strip() for row in rows]
    else:
        raise ValueError("CSV 表头必须包含 asin 列")

    if not 1 <= len(ids) <= MAX_BATCH_SIZE:
        raise ValueError(f"ASIN 文件必须有 1 到 {MAX_BATCH_SIZE} 条数据")
    asins = [asin.upper() for asin in ids]
    for i, asin in enumerate(asins, 1):
        if not re.fullmatch(r"[A-Z0-9]{10}", asin):
            raise ValueError(f"第 {i} 条数据的 ASIN 无效：{asin or '空值'}")
    return asins


def candidate_row(product: dict) -> dict:
    price = re.fullmatch(r"\$\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{2})?)", product["price"] or "")
    row = dict.fromkeys(BATCH_FIELDS, NEED_INPUT)
    values = {
        "asin": product["asin"],
        "商品名": product["title"],
        "预估售价": price.group(1).replace(",", "") if price else None,
        "头部评论数": product["reviews"].replace(",", "") if product["reviews"] else None,
        "上架时间": product["date_first_available"],
        "卖家": product["sold_by"],
        "发货方式": product["fulfillment"] if product["fulfillment"] != "unknown" else None,
        "bsr": "; ".join(product["bsr"]) if product["bsr"] else None,
        "评分": product["rating"],
        "抓取时间": datetime.now().astimezone().isoformat(timespec="seconds"),
    }
    row.update({key: value for key, value in values.items() if value is not None})
    return row


def write_batch(asins: list[str], output: Path, readme: Path) -> None:
    notes = [
        "# Amazon 商品页抓取说明",
        "",
        "`NEED_INPUT` 表示需要补录。预估售价为商品页显示的美元价，打分前请将售价和成本统一币种。",
        "头部评论数取该 ASIN 的商品页评论总数。评估头部门槛时请选用头部商品的 ASIN。",
        "品类按工作台口径补录。月搜索量、在售竞品数和成本类信息需另行补录。"
        "打分时，缺失的推广费率和供应稳定性分会使用有记录的默认值。",
        "",
        "## 各 ASIN 待补列",
        "",
    ]
    rows = []
    for i, asin in enumerate(asins):
        if i:
            time.sleep(random.uniform(2.0, 4.0))
        product = fetch_product(asin)
        row = candidate_row(product)
        rows.append(row)
        missing = "、".join(key for key, value in row.items() if value == NEED_INPUT)
        error = f"（{product['error']}）" if "error" in product else ""
        notes.append(f"- `{asin}`{error}：{missing}")

    with output.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=BATCH_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    readme.write_text("\n".join(notes) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["search", "product"])
    ap.add_argument("target", nargs="?")
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--csv", action="store_true")
    ap.add_argument("--asin-file", type=Path, help="商品批量模式，读取每行一个 ASIN 或含 asin 表头的 CSV")
    ap.add_argument("--output", type=Path, help="批量 CSV 输出路径，默认为 amazon-candidates.csv")
    a = ap.parse_args()

    if a.asin_file is not None:
        if a.mode != "product" or a.target is not None:
            ap.error("--asin-file 只用于 product 模式，且不能同时指定单个 ASIN")
        output = a.output or Path("amazon-candidates.csv")
        readme = output.with_name(output.name + ".README.md")
        try:
            if a.asin_file.resolve() in (output.resolve(), readme.resolve()):
                raise ValueError("批量输出不能覆盖 ASIN 输入文件")
            write_batch(load_asins(a.asin_file), output, readme)
        except (OSError, ValueError, csv.Error) as exc:
            ap.error(str(exc))
        print(f"CSV 写入: {output}")
        print(f"缺失列说明写入: {readme}")
        return
    if a.output is not None:
        ap.error("--output 需要与 --asin-file 一起使用")
    if a.target is None:
        ap.error("需要指定搜索词或单个 ASIN")

    if a.mode == "search":
        url = f"https://www.amazon.com/s?k={a.target.replace(' ', '+')}"
        html, code = fetch(url)
        bad = _blocked(html, code)
        if bad:
            print(json.dumps({"error": bad, "degraded": True, "rows": []}, ensure_ascii=False))
            sys.exit(0)
        rows = parse_search(html, a.limit)
        total = re.search(r"([\d,]+)\s+results for", html)
        sponsored_n = sum(1 for r in rows if r["sponsored"])
        payload = {
            "keyword": a.target,
            "total_results_text": (total.group(1) if total else None),
            "count": len(rows),
            "sponsored_count": sponsored_n,
            "ad_density": round(sponsored_n / len(rows), 3) if rows else None,
            "rows": rows,
            "degraded": None,
        }
    else:
        payload = fetch_product(a.target)

    if a.csv and a.mode == "search":
        buf = io.StringIO()
        w = csv.DictWriter(buf, fieldnames=list(payload["rows"][0].keys()) if payload["rows"] else ["asin"])
        w.writeheader()
        w.writerows(payload["rows"])
        sys.stdout.write(buf.getvalue())
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
