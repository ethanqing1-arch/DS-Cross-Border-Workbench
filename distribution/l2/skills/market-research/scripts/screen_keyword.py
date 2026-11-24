#!/usr/bin/env python3
"""汇总 Amazon 和 AliExpress 的关键词粗筛数据。"""

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from math import isfinite
from pathlib import Path
from statistics import median, quantiles
from typing import Optional


MAX_TOP = 20
DEFAULT_PRODUCT_INTERVAL = 5
SCRIPTS = Path(__file__).resolve().parent
INTEGER = r"(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)"
DECISION_WORDS = re.compile("上架测试|小批量观察|小范围观察|放弃")
CSV_HEADER = ("指标", "值", "样本量", "来源", "证据等级", "备注")


@dataclass
class Metric:
    name: str
    value: Optional[str]
    samples: str
    source: str
    note: str = ""

    def md_row(self):
        if self.value is None:
            value = f"NA（{self.note}）"
        elif self.note:
            value = f"{self.value}（{self.note}）"
        else:
            value = self.value
        cells = (self.name, value, self.samples, self.source)
        return "| " + " | ".join(md_cell(cell) for cell in cells) + " |"

    def csv_row(self):
        value = self.value if self.value is not None else "NA"
        grade = "B" if self.value is not None else "D"
        return self.name, value, self.samples, self.source, grade, self.note


def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def read_json(directory, name, *, products=False):
    try:
        data = json.loads((directory / name).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return {"error": f"缺少 {name}"}
    except (OSError, ValueError) as exc:
        return {"error": f"{name} 无法读取：{exc}"}
    if products and isinstance(data, list):
        return {"rows": data}
    if not isinstance(data, dict):
        return {"error": f"{name} 的 JSON 结构无效"}
    if products and "error" not in data and not isinstance(data.get("rows"), list):
        return {"error": f"{name} 缺少商品页记录列表"}
    return data


def load_raw(directory):
    return (
        read_json(directory, "amazon_search.json"),
        read_json(directory, "amazon_products.json", products=True),
        read_json(directory, "aliexpress_search.json"),
    )


def write_raw(directory, amazon, products, ali):
    directory.mkdir(parents=True, exist_ok=True)
    for name, data in (
        ("amazon_search.json", amazon),
        ("amazon_products.json", products),
        ("aliexpress_search.json", ali),
    ):
        with (directory / name).open("w", encoding="utf-8") as file:
            json.dump(data, file, ensure_ascii=False, indent=2)
            file.write("\n")


def collect(keyword, top, *, product_interval=DEFAULT_PRODUCT_INTERVAL, product_limit=None):
    called = False

    def fetch(script, *arguments, interval=2):
        nonlocal called
        if called and interval:
            time.sleep(interval)
        called = True
        try:
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / script), *arguments],
                capture_output=True, encoding="utf-8", errors="replace",
            )
        except OSError as exc:
            return {"error": str(exc), "_collected_at": now()}
        try:
            data = json.loads(result.stdout)
        except ValueError:
            data = None
        if not isinstance(data, dict):
            data = {"error": f"{script} 未返回 JSON 对象"}
        data["_collected_at"] = now()
        data["_exit_code"] = result.returncode
        if result.stderr.strip():
            data["_stderr"] = result.stderr.strip()
        return data

    search_args = ("--limit", str(top), "search", "--", keyword)
    amazon = fetch("fetch_amazon.py", *search_args)
    ali = fetch("fetch_aliexpress.py", *search_args)
    asins = list(dict.fromkeys(
        asin for row in search_rows(amazon, top)
        if (asin := text(row.get("asin"))) and re.fullmatch(r"[A-Z0-9]{10}", asin)
    ))[:product_limit]
    products = {"rows": []}
    consecutive_503 = 0
    for asin in asins:
        product = fetch("fetch_amazon.py", "product", asin, "--min-interval", str(product_interval),
                        interval=product_interval)
        products["rows"].append({**product, "asin": asin})
        consecutive_503 = consecutive_503 + 1 if product.get("error") == "http_503" else 0
        if consecutive_503 == 2:
            remaining = len(asins) - len(products["rows"])
            if remaining:
                products["skipped_after_503"] = remaining
            break
    return amazon, products, ali


def search_rows(source, top=None):
    rows = source.get("rows")
    if source.get("error") or not isinstance(rows, list):
        return []
    return [row if isinstance(row, dict) else {} for row in rows[:top]]


def text(value):
    return value if isinstance(value, str) and value.strip() else None


def integer(value):
    if isinstance(value, str) and re.fullmatch(INTEGER, value.strip()):
        return int(value.replace(",", ""))
    return None


def total_results(value):
    if value is None:
        return None
    number = integer(value)
    if number is not None:
        return number
    match = re.search(rf"(?:^|\bof\s+)(?:over\s+)?({INTEGER})\s+results\b", value.strip(), re.I)
    return integer(match[1]) if match else None


def number(value):
    if type(value) in (int, float) and (type(value) is int or isfinite(value)) and value >= 0:
        return value
    return None


def usd_price(value):
    match = re.fullmatch(rf"\$\s*({INTEGER}(?:\.[0-9]{{2}})?)", (text(value) or "").strip())
    return number(float(match[1].replace(",", ""))) if match else None


def age_months(value, today):
    try:
        listed = datetime.strptime((text(value) or "").strip(), "%B %d, %Y").date()
    except ValueError:
        return None
    days = (today - listed).days
    return days / 30.44 if days >= 0 else None


def field_values(rows, field, parse):
    values = (parse(row.get(field)) for row in rows)
    return [value for value in values if value is not None]


def samples(values, rows):
    return f"{len(values)}/{len(rows)}"


def missing_reason(source, rows, field):
    if source.get("error"):
        return source["error"]
    if not rows:
        return "无搜索样本"
    return f"{field} 缺失或无法解析"


def price_band(prices):
    p25, middle, p75 = quantiles(prices, n=4, method="inclusive") if len(prices) > 1 else prices * 3
    values = (min(prices), p25, middle, p75, max(prices))
    labels = ("min", "P25", "中位", "P75", "max")
    return " / ".join(f"{label} ${value:.15g}" for label, value in zip(labels, values))


def demand_metrics(amazon, rows):
    original = amazon.get("total_results_text")
    if not isinstance(original, str):
        original = None
    total = total_results(original) if rows else None
    total_note = f"原文：{original if original is not None else 'null'}"
    if total is None:
        reason = missing_reason(amazon, rows, "total_results_text")
        total_note = f"{reason}；{total_note}；解析：null"
    count, sponsored = amazon.get("count"), amazon.get("sponsored_count")
    density = None
    density_note = amazon.get("error") or "count 或 sponsored_count 缺失、无效或 count 为 0"
    valid_count = type(count) is int and count >= 0
    if not amazon.get("error") and valid_count and count > 0 and type(sponsored) is int and 0 <= sponsored <= count:
        density = f"{sponsored / count:.3f}"
        density_note = f"sponsored_count / count = {sponsored}/{count}"

    reviews = field_values(rows, "reviews", integer)
    ratings = field_values(rows, "rating", number)
    prices = field_values(rows, "price", usd_price)

    def top_metric(name, values, field, calculate):
        # 需求侧指标按完整 Top N 计算，缺字段时保留有效样本数。
        complete = bool(values) and len(values) == len(rows)
        value = str(calculate(values)) if complete else None
        note = "" if complete else missing_reason(amazon, rows, field)
        return Metric(name, value, samples(values, rows), "amazon", note)

    return [
        Metric("搜索结果总数", str(total) if total is not None else None,
               "1 页" if original is not None else "0 页", "amazon", total_note),
        Metric("广告密度", density, str(count) if valid_count else "NA", "amazon", density_note),
        top_metric("评论数中位数", reviews, "reviews", median),
        top_metric("评论数最大", reviews, "reviews", max),
        top_metric("评论数>1000占比", reviews, "reviews", lambda values: sum(value > 1000 for value in values) / len(rows)),
        top_metric("评分中位数", ratings, "rating", median),
        top_metric("价格带", prices, "price", price_band),
    ], median(prices) if prices and len(prices) == len(rows) else None


def entry_metrics(products, rows, today):
    selected_asins = {text(row.get("asin")) for row in rows} - {None}
    by_asin = {row["asin"]: row for row in search_rows(products) if text(row.get("asin")) in selected_asins}
    details = [row if not row.get("error") else {} for row in by_asin.values()]
    ages = field_values(details, "date_first_available", lambda value: age_months(value, today))
    sellers = field_values(details, "sold_by", text)
    n = len(details)
    fba = sum(row.get("fulfillment") == "fba" for row in details)
    fbm = sum(row.get("fulfillment") == "fbm" for row in details)
    fulfillment_counts = f"fba={fba}，fbm={fbm}，unknown={n - fba - fbm}"
    age_counts = f"unknown={n - len(ages)}"
    denominator = "分母为能解析出月龄的样本数"
    common_reason = products.get("error")
    if not common_reason and not n:
        common_reason = "无商品页记录" if rows else "无 Amazon 搜索样本"
    age_reason = common_reason or "date_first_available 无有效月龄"
    fulfillment_reason = common_reason or "fulfillment 无有效发货方式"
    seller_reason = common_reason or "sold_by 无有效卖家"
    return [
        Metric("上架月龄中位数", f"{median(ages):.1f}" if ages else None, samples(ages, details), "amazon",
               age_counts if ages else f"{age_reason}；{age_counts}"),
        Metric("新品占比(<12个月)", str(sum(age < 12 for age in ages) / len(ages)) if ages else None,
               str(len(ages)), "amazon", denominator if ages else f"{age_reason}；{denominator}"),
        Metric("FBA占比", str(fba / n) if fba + fbm else None, str(n), "amazon",
               fulfillment_counts if fba + fbm else f"{fulfillment_reason}；{fulfillment_counts}"),
        Metric("卖家数", str(len(set(sellers))) if sellers else None, samples(sellers, details), "amazon",
               f"有效样本 {samples(sellers, details)}" if sellers else f"{seller_reason}；有效样本 {samples(sellers, details)}"),
    ]


def supply_metrics(ali, rows, amazon_price, amazon_price_samples):
    source_reason = ali.get("error")
    if not source_reason and ali.get("currency_verified") is not True:
        source_reason = "currency_verified 未通过美元校验"
    if source_reason:
        rows = []

    def supply_median(name, field, allow_missing=False, note=""):
        values = field_values(rows, field, number)
        sample_count = samples(values, rows)
        if allow_missing:
            note = "；".join(filter(None, (note, f"有效样本 {sample_count}")))
        if values and (allow_missing or len(values) == len(rows)):
            return Metric(name, str(median(values)), sample_count, "aliexpress", note)
        return Metric(name, None, sample_count, "aliexpress", source_reason or missing_reason(ali, rows, field))

    price = supply_median("货源价中位数", "sale_price_usd", allow_missing=True, note="USD")
    discount = supply_median("货源折扣中位数", "discount_pct", note="%")
    sold = supply_median("货源销量中位数", "sold_count", allow_missing=True)
    ali_price = float(price.value) if price.value is not None else None
    multiple = f"{amazon_price / ali_price:.1f}" if amazon_price and ali_price else None
    multiple_samples = f"Amazon {amazon_price_samples}；AliExpress {price.samples}"
    unavailable = []
    if not amazon_price:
        unavailable.append("Amazon 价格中位数缺失或为 0")
    if not ali_price:
        unavailable.append("货源价中位数缺失或为 0")
    return [price, discount, sold, Metric("零货倍数", multiple, multiple_samples, "aliexpress",
                                         "；".join(unavailable) or "Amazon 价格中位数 / AliExpress 货源价中位数")]


def md_cell(value):
    return value.replace("|", r"\|").replace("\r", " ").replace("\n", " ")


def status(label, source):
    error = source.get("error")
    http = source.get("http")
    if http is None and isinstance(error, str) and re.fullmatch(r"http_[0-9]+", error):
        http = int(error[5:])
    if http is None:
        http = "NA（未返回）"
    elif http == 0:
        http = "NA（抓取器返回 0）"
    currency = source.get("currency_verified")
    timestamp = source.get("_collected_at") or "NA（未保存采集时间）"
    reasons = {key: source[key] for key in ("error", "degraded", "_stderr") if key in source}
    return (
        f"- {label}｜采集时间 {timestamp}｜http={http}"
        f"｜currency_verified={json.dumps(currency) if currency is not None else 'NA（未返回）'}"
        f"｜退出码={source.get('_exit_code', 'NA（未保存）')}"
        f"｜降级原因原文 {json.dumps(reasons, ensure_ascii=False) if reasons else 'NA（未返回）'}"
    )


def write_reports(keyword, top, out, amazon, products, ali, *, offline):
    rows = search_rows(amazon, top)
    demand, amazon_price = demand_metrics(amazon, rows)
    try:
        report_time = datetime.fromisoformat(amazon.get("_collected_at") or "")
    except (TypeError, ValueError):
        report_time = datetime.now().astimezone()
    sections = (
        ("需求侧", demand),
        ("进入难度", entry_metrics(products, rows, report_time.date())),
        ("货源侧", supply_metrics(ali, search_rows(ali, top), amazon_price, demand[-1].samples)),
    )
    lines = [f"# {md_cell(keyword)} 粗筛", "",
             f"报告基准时间 {report_time.isoformat(timespec='seconds')}｜样本量 N={len(rows)}（Amazon 搜索 Top {top}）"]
    for heading, metrics in sections:
        lines.extend(["", f"## {heading}", "", "| 指标 | 值 | 样本量 | 来源 |", "| --- | --- | --- | --- |"])
        lines.extend(metric.md_row() for metric in metrics)
    lines.extend([
        "", "## 缺口", "",
        "1688进价、运费、平均退货率、月搜索量、在售竞品数。这些不在本报告范围内，打分表会据此输出『补数据』。",
        "", "## 数据可信度", "",
        f"模式：{'离线 JSON' if offline else '在线采集'}。B 为前台抓取证据，D 为指标不可得。",
        "零货倍数使用 Amazon 搜索价与 AliExpress 美元零售价。",
        status("Amazon 搜索页", amazon),
        status("AliExpress 搜索页", ali),
    ])
    selected_asins = {text(row.get("asin")) for row in rows} - {None}
    details = [row for row in search_rows(products) if text(row.get("asin")) in selected_asins]
    if details:
        lines.extend(status(f"Amazon 商品页 {row.get('asin')}", row) for row in details)
    else:
        lines.append(status("Amazon 商品页", products if products.get("error") else {"error": "无商品页记录"}))
    skipped = products.get("skipped_after_503")
    if type(skipped) is int and skipped > 0:
        lines.append(f"- 提前停止：剩余 {skipped} 个商品页未抓，原因 503")

    out.mkdir(parents=True, exist_ok=True)
    base = keyword.replace("/", "_").replace("\\", "_") + "-粗筛"
    md_path = out / f"{base}.md"
    csv_path = out / f"{base}.csv"
    md_path.write_text(DECISION_WORDS.sub("〔已隐藏〕", "\n".join(lines) + "\n"), encoding="utf-8")
    with csv_path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(CSV_HEADER)
        for _, metrics in sections:
            writer.writerows([DECISION_WORDS.sub("〔已隐藏〕", cell) for cell in metric.csv_row()] for metric in metrics)
    print(f"Markdown 写入 {md_path}\nCSV 写入 {csv_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("keyword", help="搜索关键词")
    parser.add_argument("--top", type=int, default=MAX_TOP, help="样本上限，1 至 20，默认 20")
    parser.add_argument("--product-interval", type=float, default=DEFAULT_PRODUCT_INTERVAL,
                        help="商品页采集间隔（秒），默认 5")
    parser.add_argument("--product-limit", type=int, help="商品页采集上限，默认与 --top 相同")
    parser.add_argument("--from-json", type=Path, help="离线读取已保存的抓取 JSON")
    parser.add_argument("--out", type=Path, default=Path("out"), help="输出目录，默认 out/")
    args = parser.parse_args()
    keyword = args.keyword.strip()
    if not keyword:
        parser.error("关键词不能为空")
    if not 1 <= args.top <= MAX_TOP:
        parser.error("--top 必须在 1 到 20 之间")
    if not isfinite(args.product_interval) or args.product_interval < 0:
        parser.error("--product-interval 必须是有限的非负数")
    if args.product_limit is not None and args.product_limit < 0:
        parser.error("--product-limit 必须是非负整数")

    offline = args.from_json is not None
    try:
        if offline:
            amazon, products, ali = load_raw(args.from_json)
        else:
            amazon, products, ali = collect(keyword, args.top, product_interval=args.product_interval,
                                            product_limit=args.product_limit)
            write_raw(args.out / "raw", amazon, products, ali)
        write_reports(keyword, args.top, args.out, amazon, products, ali, offline=offline)
    except OSError as exc:
        parser.exit(1, f"无法写入报告：{exc}\n")


if __name__ == "__main__":
    main()
