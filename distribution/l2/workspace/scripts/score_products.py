#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""选品打分：需求 / 竞争 / 真实盈利 / 风险 四维打分。

盈利维度按「订单贡献利润」算，不是毛利率：
    贡献利润 = 成交收入 - 商品成本 - 平台扣费 - 物流包装 - 分摊推广费 - 退货损耗

用法:
    python3 scripts/score_products.py
    python3 scripts/score_products.py --top 5
    python3 scripts/score_products.py --category 宠物
"""
import argparse
import csv
import math
import os
import sys
from dataclasses import dataclass
from typing import Optional

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(BASE, "data", "candidates.csv")
OUT = os.path.join(BASE, "out", "选品打分.csv")

PLATFORM_FEE = 0.05   # 佣金 + 支付手续费，按售价比例
GROSS_FLOOR = 0.25    # 毛利率红线：低于此值不进付费测款
CONTRIB_FLOOR = 0.08  # 贡献利润率红线：低于此值不做付费主推

DEFAULTS = {"推广费率": 0.15, "供应稳定性分": 5}
WEIGHTS = {"需求": 0.25, "竞争": 0.25, "利润": 0.30, "风险": 0.20}
RESULTS_REFERENCE = 10_000
REVIEWS_REFERENCE = 1_000  # 粗筛的高评论占比分界
AGE_REFERENCE = 12        # 粗筛的新品月龄分界
PRIMARY = {
    "需求": ("月搜索量",),
    "竞争": ("在售竞品数", "头部评论数"),
    "利润": ("预估售价", "1688进价", "运费", "平均退货率"),
    "风险": ("平均退货率", "供应稳定性分"),
}
SECONDARY = {
    "需求": ("搜索结果总数", "广告密度"),
    "竞争": ("评论数中位数", "评论数>1000占比", "评分中位数"),
    "风险": ("上架月龄中位数", "FBA占比"),
}
INPUT_FIELDS = tuple(dict.fromkeys(
    field for fields in (*PRIMARY.values(), *SECONDARY.values(), tuple(DEFAULTS)) for field in fields
))
UPPER_BOUNDS = {
    "平均退货率": 1, "广告密度": 1, "评论数>1000占比": 1,
    "评分中位数": 5, "供应稳定性分": 10, "FBA占比": 1,
}
SOURCE_STATUS = "Amazon证据状态"
OUTPUT_FIELDS = [
    "商品名", "品类", "预估售价", "表面毛利", "贡献利润", "贡献利润率", "分层",
    "月搜索量", "在售竞品数", "供需比", "退货率", "总分", "决策", "诊断", "红线", "差异化点",
    "证据等级", "可算维度", "缺口",
]


@dataclass
class Candidate:
    row: dict
    values: dict
    sources: dict
    profit: Optional[dict]
    defaults_used: list


def num(row, key):
    try:
        value = float(row.get(key))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def load(path):
    if not os.path.exists(path):
        sys.exit("缺少文件: %s" % path)
    with open(path, newline="", encoding="utf-8-sig") as f:
        return [r for r in csv.DictReader(f) if (r.get("商品名") or "").strip()]


def minmax(values):
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return [0.5 for _ in values]
    return [(v - lo) / (hi - lo) for v in values]


def profit_model(price, cost, ship, ad_rate, ret_rate):
    """三层利润里的第二层：订单贡献利润。"""
    platform = price * PLATFORM_FEE
    ad = price * ad_rate
    # 退货损耗按退回货不能再销售计：损失货款 + 运费 + 已发生的平台费
    ret_loss = ret_rate * (cost + ship + platform)
    gross = price - cost
    contribution = price - cost - platform - ship - ad - ret_loss
    return {
        "gross": gross,
        "gross_rate": gross / price,
        "contribution": contribution,
        "contrib_rate": contribution / price,
        "platform": platform,
        "ad": ad,
        "ret_loss": ret_loss,
    }


def tier_of(contrib_rate, contrib):
    if contrib <= 0:
        return "不做"
    if contrib_rate < CONTRIB_FLOOR:
        return "清仓款"
    if contrib_rate < 0.18:
        return "引流款"
    return "利润款"


def prepare(row):
    # 只接受白名单中的原始列名，估算_ 前缀不会进入计算。
    values = {key: num(row, key) for key in INPUT_FIELDS}
    for key, value in values.items():
        if value is not None and (value < 0 or value > UPPER_BOUNDS.get(key, math.inf)):
            values[key] = None
    if values["预估售价"] == 0:
        values["预估售价"] = None

    sources = {}
    for dimension, fields in PRIMARY.items():
        if all(values[key] is not None for key in fields):
            sources[dimension] = "一级"
        elif dimension in SECONDARY and all(values[key] is not None for key in SECONDARY[dimension]):
            sources[dimension] = "代理" if dimension == "需求" else "二级"

    defaults_used = []
    if "风险" not in sources and values["平均退货率"] is not None:
        sources["风险"] = "默认"
        values["供应稳定性分"] = DEFAULTS["供应稳定性分"]
        defaults_used.append("供应稳定性分=%s" % values["供应稳定性分"])

    model = None
    if "利润" in sources:
        ad_rate = values["推广费率"]
        if ad_rate is None:
            ad_rate = DEFAULTS["推广费率"]
            defaults_used.append("推广费率=%s" % ad_rate)
        price, cost, ship, ret = (values[key] for key in PRIMARY["利润"])
        model = profit_model(price, cost, ship, ad_rate, ret)
    return Candidate(row, values, sources, model, defaults_used)


def relative_scores(candidates, dimension, source, features):
    # 相同证据口径分别归一，只有单一维度的行不参与其他候选的相对排名。
    samples = {index: features(candidate) for index, candidate in enumerate(candidates)
               if len(candidate.sources) >= 2 and candidate.sources.get(dimension) == source}
    columns = [minmax(column) for column in zip(*samples.values())]
    return dict(zip(samples, zip(*columns)))


def score_dimensions(candidates):
    scores = [{} for _ in candidates]
    for index, (demand,) in relative_scores(candidates, "需求", "一级", lambda c: (
        math.log1p(c.values["月搜索量"]),
    )).items():
        scores[index]["需求"] = demand
    for index, (count, head) in relative_scores(candidates, "竞争", "一级", lambda c: (
        math.log1p(c.values["在售竞品数"]), math.log1p(c.values["头部评论数"]),
    )).items():
        scores[index]["竞争"] = 1.0 - (0.7 * count + 0.3 * head)
    for index, (contribution, rate) in relative_scores(candidates, "利润", "一级", lambda c: (
        math.log1p(max(c.profit["contribution"], 0.01)), c.profit["contrib_rate"],
    )).items():
        scores[index]["利润"] = 0.6 * contribution + 0.4 * rate
    for index, candidate in enumerate(candidates):
        if len(candidate.sources) < 2:
            continue
        values, sources = candidate.values, candidate.sources
        if sources.get("需求") == "代理":
            results = min(1.0, math.log1p(values["搜索结果总数"]) / math.log1p(RESULTS_REFERENCE))
            scores[index]["需求"] = 0.7 * results + 0.3 * values["广告密度"]
        if sources.get("竞争") == "二级":
            reviews = min(1.0, math.log1p(values["评论数中位数"]) / math.log1p(REVIEWS_REFERENCE))
            pressure = (reviews + values["评论数>1000占比"] + values["评分中位数"] / 5.0) / 3.0
            scores[index]["竞争"] = 1.0 - pressure
        if sources.get("风险") == "二级":
            age = min(1.0, values["上架月龄中位数"] / AGE_REFERENCE)
            scores[index]["风险"] = 1.0 - (age + values["FBA占比"]) / 2.0
        elif sources.get("风险") in ("一级", "默认"):
            ret_pen = max(0.1, 1.0 - values["平均退货率"] * 3.0)
            scores[index]["风险"] = 0.5 * ret_pen + 0.5 * values["供应稳定性分"] / 10.0
    return scores


def missing_fields(values, fields):
    return "、".join(key for key in fields if values[key] is None)


def score_row(candidate, scores):
    row, values, sources, model = candidate.row, candidate.values, candidate.sources, candidate.profit
    count = len(sources)
    price, search, comp, ret = (values[key] for key in ("预估售价", "月搜索量", "在售竞品数", "平均退货率"))
    result = {
        "商品名": row["商品名"], "品类": row.get("品类", ""), "差异化点": row.get("差异化点", ""),
        "预估售价": "%.2f" % price if price is not None else "",
        "月搜索量": int(search) if search is not None else "",
        "在售竞品数": int(comp) if comp is not None else "",
        "供需比": "%.1f" % (search / max(comp, 1.0)) if search is not None and comp is not None else "",
        "退货率": "%.1f%%" % (ret * 100) if ret is not None else "",
    }
    flags, reasons, gaps = [], [], []
    for dimension, fields in PRIMARY.items():
        if dimension not in sources:
            label = "利润未验" if dimension == "利润" else dimension
            gap = f"{label}缺少或无有效值：{missing_fields(values, fields)}"
            if dimension in SECONDARY:
                gap += f"（后备缺少或无有效值：{missing_fields(values, SECONDARY[dimension])}）"
            gaps.append(gap)

    if model is not None:
        if model["gross_rate"] < GROSS_FLOOR:
            flags.append("毛利率<25%不进付费测款")
        if model["contrib_rate"] < CONTRIB_FLOOR:
            flags.append("贡献利润率<8%不做主推")
            reasons.append("贡献利润薄")
        elif model["contrib_rate"] >= 0.18:
            reasons.append("贡献利润厚")
        if model["contribution"] < 0:
            flags.append("贡献利润为负")
        result.update({
            "表面毛利": "%.2f" % model["gross"], "贡献利润": "%.2f" % model["contribution"],
            "贡献利润率": "%.1f%%" % (model["contrib_rate"] * 100),
            "分层": tier_of(model["contrib_rate"], model["contribution"]),
        })

    level = "B"
    if sources.get("需求") == "代理":
        level = "C"
        reasons.append("需求代理：搜索结果总数及广告密度")
    elif count == len(WEIGHTS) and all(source == "一级" for source in sources.values()):
        level = "A"

    if model is None:
        listing_blocked = True  # 利润未验时，其他维度的高分不能放行上架。
        flags.append("利润未验")
        if count >= 2:
            reasons.append("利润未验")
    else:
        listing_blocked = count < len(WEIGHTS) or bool(flags)

    if model is not None and model["contribution"] <= 0:
        action = "放弃"
    elif count < 2:
        action = "补数据"
        level = "D"
    else:
        action = "小批量观察"

    if scores:
        score = 100.0 * sum(WEIGHTS[key] * value for key, value in scores.items()) / sum(
            WEIGHTS[key] for key in scores
        )
        result["总分"] = "%.1f" % score
        if action != "放弃":
            if score >= 60 and not listing_blocked and level != "C":
                action = "上架测试"
            elif score < 48:
                action = "放弃"
        if scores.get("需求") is not None and scores["需求"] > 0.7 and sources["需求"] == "一级":
            reasons.append("需求旺")
        if scores.get("竞争") is not None and scores["竞争"] > 0.65:
            reasons.append("竞争小")
        if sources.get("竞争") == "二级" and scores["竞争"] < 0.35:
            reasons.append("Amazon 搜索页显示竞争强")
        if sources.get("风险") == "二级" and scores["风险"] < 0.35:
            reasons.append("Amazon 商品页显示进入难度高")

    if ret is not None and ret > 0.12:
        reasons.append("退货偏高")
    if sources.get("风险") in ("一级", "默认") and values["供应稳定性分"] < 6:
        reasons.append("供应不稳")
    if row.get(SOURCE_STATUS):
        reasons.append(row[SOURCE_STATUS])
    if candidate.defaults_used:
        reasons.append("使用默认值：" + "、".join(candidate.defaults_used))
    if count < 2:
        reasons.extend(gaps)
    result.update({
        "决策": action, "诊断": "/".join(reasons) or "中规中矩", "红线": "/".join(flags),
        "证据等级": level, "可算维度": f"{count}/{len(WEIGHTS)}", "缺口": "；".join(gaps),
    })
    return result


def build(rows):
    candidates = [prepare(row) for row in rows]
    out = [score_row(row, scores) for row, scores in zip(candidates, score_dimensions(candidates))]
    return sorted(out, key=lambda result: -float(result.get("总分", "-inf")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=0)
    ap.add_argument("--category", default="")
    a = ap.parse_args()

    rows = load(SRC)
    if a.category:
        rows = [r for r in rows if a.category in (r.get("品类") or "")]
    if not rows:
        sys.exit("没有匹配的候选品")

    res = build(rows)
    if a.top:
        res = res[: a.top]

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    path = OUT if not a.category else OUT.replace(".csv", "_%s.csv" % a.category)
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=OUTPUT_FIELDS)
        w.writeheader()
        w.writerows(res)

    print("贡献利润口径：售价 - 成本 - 平台5% - 运费 - 推广费 - 退货损耗\n")
    display_fields = ["贡献利润", "贡献利润率", "分层", "总分", "决策", "诊断", "证据等级", "可算维度", "缺口"]
    print(" | ".join(["排名", "商品名"] + display_fields))
    print("-" * 88)
    for i, r in enumerate(res, 1):
        print(" | ".join([str(i), r["商品名"][:14]] + [r.get(key, "") for key in display_fields]))
    print("\n明细写入: %s" % path)

    blocked = [r for r in res if r.get("红线")]
    if blocked:
        print("\n触发红线 %d 个：" % len(blocked))
        for r in blocked:
            print("  - %s：%s" % (r["商品名"], r["红线"]))

    test = [r for r in res if r["决策"] == "上架测试"]
    if test:
        print("\n下一步：%d 个可上架测试" % len(test))
        for r in test:
            print("  - %s  售价 %s  单件贡献 %s（%s）" % (r["商品名"], r["预估售价"], r["贡献利润"], r["分层"]))


if __name__ == "__main__":
    main()
