#!/usr/bin/env python3
"""把一个关键词的粗筛实测值转换成一行选品候选。"""

import argparse
import csv
import sys
from datetime import datetime
from pathlib import Path

# 该脚本和粗筛模块运行时不在工作区或 skills 镜像生成缓存。
sys.dont_write_bytecode = True
from score_products import INPUT_FIELDS, SOURCE_STATUS, num


WORKSPACE = Path(__file__).resolve().parent.parent
SEARCH_METRICS = {
    "搜索结果总数": "搜索结果总数", "广告密度": "广告密度", "评论数中位数": "评论数中位数",
    "评论数最大": "头部评论数", "评论数>1000占比": "评论数>1000占比", "评分中位数": "评分中位数",
}
PRODUCT_METRICS = {"上架月龄中位数": "上架月龄中位数", "FBA占比": "FBA占比"}
FIELDS = ("品类", "商品名", *INPUT_FIELDS, "差异化点", SOURCE_STATUS)


def read_screen_csv(path):
    with path.open(encoding="utf-8-sig", newline="") as file:
        reader = csv.DictReader(file)
        if not {"指标", "值", "来源", "证据等级", "备注"}.issubset(reader.fieldnames or ()):
            raise ValueError("输入 CSV 缺少粗筛表头")
        return {row["指标"]: row for row in reader}


def read_raw(directory, keyword):
    if (directory / "raw").is_dir():
        directory /= "raw"
    if not directory.is_dir() or not any((directory / name).is_file() for name in (
        "amazon_search.json", "amazon_products.json", "aliexpress_search.json",
    )):
        raise ValueError(f"{directory} 缺少粗筛原始 JSON")
    for skills in (WORKSPACE / ".dsh" / "skills", WORKSPACE.parent / "skills"):
        scripts = skills / "market-research" / "scripts"
        if (scripts / "screen_keyword.py").is_file():
            sys.path.insert(0, str(scripts))
            import screen_keyword as screen
            break
    else:
        raise ValueError("找不到 L2 market-research 的 screen_keyword.py，无法读取原始 JSON")

    amazon, products, ali = screen.load_raw(directory)
    for record in (amazon, ali):
        observed_keyword = screen.text(record.get("keyword"))
        if observed_keyword and observed_keyword.strip().casefold() != keyword.casefold():
            raise ValueError(f"--keyword 与原始 JSON 的关键词不符：{observed_keyword!r}")
    rows = screen.search_rows(amazon)
    demand, _ = screen.demand_metrics(amazon, rows)
    try:
        reported = datetime.fromisoformat(amazon.get("_collected_at") or "")
    except (TypeError, ValueError):
        reported = datetime.now().astimezone()
    entry = screen.entry_metrics(products, rows, reported.date())
    return {metric.name: dict(zip(screen.CSV_HEADER, metric.csv_row())) for metric in demand + entry}


def candidate(keyword, price, metrics):
    row = {"品类": keyword, "商品名": keyword, "预估售价": price}
    for metric, field in {**SEARCH_METRICS, **PRODUCT_METRICS}.items():
        evidence = metrics.get(metric, {})
        if evidence.get("来源") == "amazon" and evidence.get("证据等级") == "B":
            value = num(evidence, "值")
            if value is not None and value >= 0:
                row[field] = evidence["值"]

    if not any(field in row for field in SEARCH_METRICS.values()):
        note = metrics.get("搜索结果总数", {}).get("备注") or "无可用搜索样本"
        row[SOURCE_STATUS] = "因为 Amazon 不可用（搜索页：%s）" % note.split("；", 1)[0]
    else:
        missing = [name for name in PRODUCT_METRICS if name not in row]
        if missing:
            notes = dict.fromkeys(
                note for name in missing if (note := metrics.get(name, {}).get("备注"))
            )
            reason = "；".join(notes) or "、".join(missing)
            row[SOURCE_STATUS] = f"Amazon 商品页证据不全（{reason}）"
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--from-json", type=Path, help="raw 目录或含 raw 的粗筛输出目录")
    source.add_argument("--from-csv", type=Path, help="关键词粗筛 CSV")
    source.add_argument("screen_csv", type=Path, nargs="?", help="关键词粗筛 CSV")
    parser.add_argument("--keyword", required=True, help="粗筛的关键词")
    parser.add_argument("--price", required=True, help="与成本同币种的售价，必须大于 0")
    parser.add_argument("--out", type=Path, default=WORKSPACE / "data" / "candidates.csv", help="候选 CSV 输出路径")
    args = parser.parse_args()
    keyword = args.keyword.strip()
    price = num({"price": args.price}, "price")
    if not keyword:
        parser.error("--keyword 不能为空")
    if price is None or price <= 0:
        parser.error("--price 必须是有限的正数")
    source_csv = args.from_csv or args.screen_csv
    if source_csv and source_csv.resolve() == args.out.resolve():
        parser.error("粗筛 CSV 和候选 CSV 必须使用不同路径")

    try:
        metrics = read_screen_csv(source_csv) if source_csv else read_raw(args.from_json, keyword)
        row = candidate(keyword, args.price, metrics)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("w", encoding="utf-8-sig", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerow(row)
    except (OSError, ValueError, csv.Error) as exc:
        parser.exit(1, f"候选转换失败：{exc}\n")
    print(f"候选 CSV 写入 {args.out}")


if __name__ == "__main__":
    main()
