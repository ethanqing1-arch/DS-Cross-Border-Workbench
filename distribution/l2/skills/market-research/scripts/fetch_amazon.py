#!/usr/bin/env python3
"""
免费 Amazon 调研抓取器（零依赖：只用标准库 + 系统 curl）

设计依据（2026-11-22 实测）：
  curl + 正常 UA + i18n-prefs=USD  → 200，48 张卡片，四字段齐全
  内置网页抓取器 / read_url        → 503（指纹被拦）
  Playwright + 本机 Chrome         → 200，能渲染，但评论原文仍需登录

所以：HTTP 为主（快、可并发），Playwright 只在需要交互时另走 supplement.mjs。
拿不到就返回 null + degraded，绝不编数字。

用法：
  python3 fetch_amazon.py search "pet slow feeder" --limit 20
  python3 fetch_amazon.py product B0C5HSCS8J
  python3 fetch_amazon.py search "dog bowl" --limit 30 --csv
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys, time, random, csv, io

UA_POOL = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
]
COOKIE = "i18n-prefs=USD; lc-main=en_US"


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
            time.sleep(1.5 * (i + 1) + random.random())
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
        "degraded": None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["search", "product"])
    ap.add_argument("target")
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--csv", action="store_true")
    a = ap.parse_args()

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
        html, code = fetch(f"https://www.amazon.com/dp/{a.target}")
        bad = _blocked(html, code)
        if bad:
            print(json.dumps({"error": bad, "degraded": True, "asin": a.target}, ensure_ascii=False))
            sys.exit(0)
        payload = parse_product(html, a.target)

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
