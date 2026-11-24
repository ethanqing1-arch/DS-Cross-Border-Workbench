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

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(BASE, "data", "candidates.csv")
OUT = os.path.join(BASE, "out", "选品打分.csv")

PLATFORM_FEE = 0.05   # 佣金 + 支付手续费，按售价比例
GROSS_FLOOR = 0.25    # 毛利率红线：低于此值不进付费测款
CONTRIB_FLOOR = 0.08  # 贡献利润率红线：低于此值不做付费主推


def num(row, key, default=0.0):
    try:
        return float(str(row.get(key, default)).strip() or default)
    except ValueError:
        return default


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
        "gross_rate": gross / price if price else 0.0,
        "contribution": contribution,
        "contrib_rate": contribution / price if price else 0.0,
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


def build(rows):
    search = [num(r, "月搜索量") for r in rows]
    comp = [num(r, "在售竞品数") for r in rows]
    head = [num(r, "头部评论数") for r in rows]

    models = []
    for r in rows:
        price = num(r, "预估售价")
        cost = num(r, "1688进价")
        ship = num(r, "运费")
        ad = num(r, "推广费率", 0.15)
        ret = num(r, "平均退货率")
        if price <= 0:
            sys.exit("「%s」的预估售价必须大于 0" % r["商品名"])
        models.append(profit_model(price, cost, ship, ad, ret))

    d_search = minmax([math.log1p(v) for v in search])
    d_comp = minmax([math.log1p(v) for v in comp])
    d_head = minmax([math.log1p(v) for v in head])
    d_contrib_abs = minmax([math.log1p(max(m["contribution"], 0.01)) for m in models])
    d_contrib_rate = minmax([m["contrib_rate"] for m in models])

    out = []
    for i, r in enumerate(rows):
        m = models[i]
        price = num(r, "预估售价")
        ret = num(r, "平均退货率")
        supply = num(r, "供应稳定性分", 5) / 10.0
        ret_pen = max(0.1, 1.0 - ret * 3.0)
        ratio = search[i] / max(comp[i], 1.0)

        pressure = 0.7 * d_comp[i] + 0.3 * d_head[i]
        profit = 0.6 * d_contrib_abs[i] + 0.4 * d_contrib_rate[i]
        risk = 0.5 * ret_pen + 0.5 * supply

        score = 100.0 * (0.25 * d_search[i] + 0.25 * (1.0 - pressure) + 0.30 * profit + 0.20 * risk)

        flags = []
        if m["gross_rate"] < GROSS_FLOOR:
            flags.append("毛利率<25%不进付费测款")
        if m["contrib_rate"] < CONTRIB_FLOOR:
            flags.append("贡献利润率<8%不做主推")
        if m["contribution"] <= 0:
            flags.append("贡献利润为负")

        if score >= 60 and not flags:
            action = "上架测试"
        elif score >= 48 and m["contribution"] > 0:
            action = "小批量观察"
        else:
            action = "放弃"

        reasons = []
        if d_search[i] > 0.7:
            reasons.append("需求旺")
        if d_comp[i] < 0.35:
            reasons.append("竞争小")
        if d_head[i] < 0.4:
            reasons.append("头部壁垒低")
        if m["contrib_rate"] >= 0.18:
            reasons.append("贡献利润厚")
        elif m["contrib_rate"] < CONTRIB_FLOOR:
            reasons.append("贡献利润薄")
        if ret > 0.12:
            reasons.append("退货偏高")
        if supply < 0.6:
            reasons.append("供应不稳")

        out.append({
            "商品名": r["商品名"],
            "品类": r.get("品类", ""),
            "预估售价": "%.2f" % price,
            "表面毛利": "%.2f" % m["gross"],
            "贡献利润": "%.2f" % m["contribution"],
            "贡献利润率": "%.1f%%" % (m["contrib_rate"] * 100),
            "分层": tier_of(m["contrib_rate"], m["contribution"]),
            "月搜索量": int(search[i]),
            "在售竞品数": int(comp[i]),
            "供需比": "%.1f" % ratio,
            "退货率": "%.1f%%" % (ret * 100),
            "总分": "%.1f" % score,
            "决策": action,
            "诊断": "/".join(reasons) if reasons else "中规中矩",
            "红线": "/".join(flags) if flags else "",
            "差异化点": r.get("差异化点", ""),
        })
    out.sort(key=lambda x: -float(x["总分"]))
    return out


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
        w = csv.DictWriter(f, fieldnames=list(res[0].keys()))
        w.writeheader()
        w.writerows(res)

    print("贡献利润口径：售价 - 成本 - 平台5% - 运费 - 推广费 - 退货损耗\n")
    head = ["排名", "商品名", "贡献利润", "贡献率", "分层", "总分", "决策"]
    print(" | ".join(head))
    print("-" * 88)
    for i, r in enumerate(res, 1):
        print(" | ".join([str(i), r["商品名"][:14], r["贡献利润"], r["贡献利润率"],
                          r["分层"], r["总分"], r["决策"]]))
    print("\n明细写入: %s" % path)

    blocked = [r for r in res if r["红线"]]
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
