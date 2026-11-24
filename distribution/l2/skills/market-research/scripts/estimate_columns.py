#!/usr/bin/env python3
"""从关键词粗筛数据估算缺列，并保留打分所需的证据边界。"""

import argparse
import csv
import re
import sys
from math import isfinite
from pathlib import Path

# L2 安装会逐文件比较 skills 和 bundle/skills。
previous_bytecode_setting = sys.dont_write_bytecode
sys.dont_write_bytecode = True
try:
    from screen_keyword import CSV_HEADER, demand_metrics, integer, load_raw, search_rows, supply_metrics, text
finally:
    sys.dont_write_bytecode = previous_bytecode_setting


ESTIMATE_HEADER = ("指标", "估算值", "公式", "证据等级", "不确定性", "备注")


def read_screen_csv(path):
    with path.open(encoding="utf-8-sig", newline="") as file:
        reader = csv.DictReader(file)
        if not set(CSV_HEADER).issubset(reader.fieldnames or ()):
            raise ValueError("输入 CSV 缺少粗筛表头")
        metrics = {row["指标"]: row for row in reader}
    return path.stem.removesuffix("-粗筛"), metrics


def read_screen_json(directory):
    if (directory / "raw").is_dir():
        directory /= "raw"
    if not any((directory / name).is_file() for name in ("amazon_search.json", "aliexpress_search.json")):
        raise ValueError(f"{directory} 缺少搜索抓取 JSON")
    amazon, _, ali = load_raw(directory)
    demand, amazon_price = demand_metrics(amazon, search_rows(amazon))
    supply = supply_metrics(ali, search_rows(ali), amazon_price, demand[-1].samples)
    metrics = {metric.name: dict(zip(CSV_HEADER, metric.csv_row())) for metric in demand + supply}
    keyword = text(amazon.get("keyword")) or text(ali.get("keyword")) or "关键词粗筛"
    return keyword, metrics


def observed(row, source):
    if row.get("来源") == source and row.get("证据等级") == "B":
        return row.get("值")
    return None


def positive(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return isfinite(number) and number > 0


def estimate_proxy(name, row, value, input_name, formula, uncertainty):
    note = f"输入指标 {input_name}={row.get('值') or 'NA'}"
    if value is None:
        note += "。缺少经验证的正数。"
        if row.get("备注"):
            note += f"粗筛备注 {row['备注']}"
    grade = "D" if value is None else "C"
    return f"估算_{name}", "NA" if value is None else str(value), formula, grade, uncertainty, note


def estimates(metrics):
    results = metrics.get("搜索结果总数", {})
    count = integer(observed(results, "amazon"))
    source_price = metrics.get("货源价中位数", {})
    price = observed(source_price, "aliexpress")
    return [
        estimate_proxy(
            "在售竞品数", results, count or None, "Amazon 搜索结果总数",
            "在售竞品数代理值 = 搜索结果总数",
            "搜索命中可能纳入重复变体和不在售商品，通常高估在售竞品数，也可能漏掉未被搜索索引的商品。",
        ),
        estimate_proxy(
            "1688进价", source_price, price if positive(price) else None, "AliExpress 美元货源价中位数",
            "美元上界参考 = 已校验币种的 AliExpress 货源价中位数",
            "AliExpress 零售价只作 USD 上界参考，1688 实际报价受规格、起订量和批发条件影响。",
        ),
        ("估算_月搜索量", "NA", "月搜索量 = 关键词在指定月份的搜索事件数", "D",
         "搜索结果总数衡量命中商品，无法反映月内搜索次数。", "缺少输入指标 关键词月度搜索事件数"),
        ("估算_平均退货率", "NA", "平均退货率 = 同一订单群的退货订单数 / 已发货订单数", "D",
         "退货率受品类、渠道和观察窗口影响。", "缺少输入指标 同口径退货订单数和已发货订单数"),
        ("估算_运费", "NA", "运费 = 承运商按路线和计费重量给出的单票报价", "D",
         "实际运费随目的地、计费重量和配送服务变化。", "缺少输入指标 发货地、目的地、计费重量和承运商报价"),
    ]


def score_input(keyword, metrics, rows, supplied_price):
    band = observed(metrics.get("价格带", {}), "amazon")
    middle = re.search(r"(?:^| / )中位 \$([^ ]+)", band or "")
    price = supplied_price if supplied_price is not None else (middle[1] if middle else None)
    if not positive(price):
        raise ValueError("打分脚本需要大于 0 的预估售价。Amazon 价格带不可用时请通过 --score-price 提供已知售价")
    score = {
        "商品名": keyword,
        "预估售价": price,
        "头部评论数": observed(metrics.get("评论数最大", {}), "amazon") or "",
    }
    score.update((row[0], row[1]) for row in rows)
    return score


def write_csv(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(header)
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("screen_csv", type=Path, nargs="?", help="关键词粗筛 CSV")
    source.add_argument("--from-json", type=Path, help="抓取 JSON 目录或含 raw/ 的粗筛输出目录")
    parser.add_argument("--out", type=Path, required=True, help="估算表输出路径")
    parser.add_argument("--as-score-input", type=Path, help="额外输出选品打分的候选 CSV")
    parser.add_argument("--score-price", help="打分候选的已知售价，默认取 Amazon 价格带的中位数")
    args = parser.parse_args()
    if args.score_price is not None and args.as_score_input is None:
        parser.error("--score-price 需要与 --as-score-input 一起使用")

    outputs = [args.out]
    if args.as_score_input is not None:
        outputs.append(args.as_score_input)
    resolved_outputs = {path.resolve() for path in outputs}
    if len(resolved_outputs) != len(outputs) or (args.screen_csv and args.screen_csv.resolve() in resolved_outputs):
        parser.error("估算表、打分输入和来源 CSV 必须使用不同路径")

    try:
        if args.screen_csv is not None:
            keyword, metrics = read_screen_csv(args.screen_csv)
        else:
            keyword, metrics = read_screen_json(args.from_json)
        rows = estimates(metrics)
        score = score_input(keyword, metrics, rows, args.score_price) if args.as_score_input is not None else None
        write_csv(args.out, ESTIMATE_HEADER, rows)
        if score is not None:
            write_csv(args.as_score_input, score.keys(), [score.values()])
    except (OSError, ValueError, csv.Error) as exc:
        parser.exit(1, f"估算失败：{exc}\n")


if __name__ == "__main__":
    main()
