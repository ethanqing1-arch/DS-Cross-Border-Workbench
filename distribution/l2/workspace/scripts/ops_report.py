#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""运营日报：按「五模块」结构出看板，利润按「订单贡献利润」口径。

    贡献利润 = 实付金额 - 商品成本 - 平台扣费 - 物流 - 推广费分摊 - 退货损耗

指标口径（写死，不要临时改，否则趋势不可比）：
    GMV      = Σ 实付金额（下单且未取消，按支付时间归日）
    净销售额 = GMV - Σ 退款金额
    退款率   = Σ 退款金额 / GMV        （按金额，不按订单数）
    客单价   = 净销售额 / 成交用户数    （不按订单数）
    ROI      = GMV / Σ 推广费分摊      （GMV 口径，便于横向比；真实投产看贡献利润/推广费）

用法:
    python3 scripts/ops_report.py
    python3 scripts/ops_report.py --days 7
"""
import argparse
import csv
import os
import sys
from collections import defaultdict

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORDERS = os.path.join(BASE, "data", "orders.csv")
PRODUCTS = os.path.join(BASE, "data", "products.csv")
OUT = os.path.join(BASE, "out", "运营日报.md")

PLATFORM_FEE = 0.05
# 异常阈值（必须量化，否则永远"一切正常"）
W_REFUND_RATE = 0.12     # 整体退款率
W_SKU_REFUND = 0.30      # 单品退款率
W_DROP = 0.20            # 单日净销售额环比跌幅
W_PENDING = 2            # 待发货积压单量
W_LOW_STOCK = 30         # 库存预警线
W_ZERO_DAYS = 7          # 连续零销量天数


def fnum(v):
    try:
        return float(str(v).strip() or 0)
    except ValueError:
        return 0.0


def load(path):
    if not os.path.exists(path):
        sys.exit("缺少文件: %s" % path)
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=0, help="只看最近 N 天（0=全部）")
    a = ap.parse_args()

    orders = load(ORDERS)
    prods = {p["SKU"]: p for p in load(PRODUCTS) if p.get("SKU")}

    dates = sorted({o["日期"] for o in orders})
    if a.days and len(dates) > a.days:
        keep = set(dates[-a.days:])
        orders = [o for o in orders if o["日期"] in keep]
        dates = sorted(keep)

    pay = sum(fnum(o["实付金额"]) for o in orders)
    refund = sum(fnum(o["退款金额"]) for o in orders)
    ad = sum(fnum(o.get("推广费分摊")) for o in orders)
    net = pay - refund
    n = len(orders)
    buyers = {o.get("买家ID") or o["订单号"] for o in orders}

    by_day = defaultdict(lambda: {"pay": 0.0, "refund": 0.0, "n": 0})
    by_sku = defaultdict(lambda: {"qty": 0, "pay": 0.0, "refund": 0.0, "ad": 0.0, "n": 0})
    by_ch = defaultdict(lambda: {"n": 0, "pay": 0.0, "refund": 0.0})
    status = defaultdict(int)

    for o in orders:
        d, s = o["日期"], o["SKU"]
        p, r, adf = fnum(o["实付金额"]), fnum(o["退款金额"]), fnum(o.get("推广费分摊"))
        q = int(fnum(o["数量"]))
        by_day[d]["pay"] += p
        by_day[d]["refund"] += r
        by_day[d]["n"] += 1
        by_sku[s]["qty"] += q
        by_sku[s]["pay"] += p
        by_sku[s]["refund"] += r
        by_sku[s]["ad"] += adf
        by_sku[s]["n"] += 1
        ch = o.get("渠道") or "未知"
        by_ch[ch]["n"] += 1
        by_ch[ch]["pay"] += p
        by_ch[ch]["refund"] += r
        status[o["状态"]] += 1

    # 贡献利润（逐单累加）
    sku_rows = []
    for s, v in by_sku.items():
        prod = prods.get(s, {})
        cost_unit = fnum(prod.get("进价"))
        ship_unit = fnum(prod.get("运费"))
        cost = cost_unit * v["qty"]
        ship = ship_unit * v["qty"]
        platform = v["pay"] * PLATFORM_FEE
        contrib = v["pay"] - cost - platform - ship - v["ad"] - v["refund"]
        contrib_rate = contrib / v["pay"] if v["pay"] else 0.0
        sku_rows.append({
            "SKU": s,
            "商品名": prod.get("商品名", s),
            "件数": v["qty"],
            "GMV": "%.2f" % v["pay"],
            "退款": "%.2f" % v["refund"],
            "推广费": "%.2f" % v["ad"],
            "贡献利润": "%.2f" % contrib,
            "贡献率": "%.1f%%" % (contrib_rate * 100),
            "_contrib": contrib,
            "_rate": contrib_rate,
            "退款率": "%.1f%%" % (v["refund"] / v["pay"] * 100 if v["pay"] else 0),
        })
    sku_rows.sort(key=lambda x: -x["_contrib"])

    total_contrib = sum(r["_contrib"] for r in sku_rows)
    roi = pay / ad if ad else 0.0
    real_roi = total_contrib / ad if ad else 0.0

    # ---------------- 预警 ----------------
    warns = []
    rr = refund / pay if pay else 0
    if rr > W_REFUND_RATE:
        warns.append(("退款率", "%.1f%% > %.0f%%" % (rr * 100, W_REFUND_RATE * 100),
                      "抽查最近 10 单退货原因，比对详情页描述与实物"))
    pending = status.get("待发货", 0)
    if pending > W_PENDING:
        warns.append(("待发货积压", "%d 单 > %d 单" % (pending, W_PENDING), "当天 18 点前全部出库"))
    for r in sku_rows:
        if r["退款率"] and float(r["退款率"].rstrip("%")) > W_SKU_REFUND * 100:
            warns.append(("%s 退款率" % r["SKU"], r["退款率"], "暂停推广，先查质量或描述不符"))
        if r["_contrib"] < 0:
            warns.append(("%s 贡献利润为负" % r["SKU"], r["贡献利润"], "核对成本与推广，两周无改善下架"))
    if len(dates) >= 2:
        last, prev = dates[-1], dates[-2]
        lv = by_day[last]["pay"] - by_day[last]["refund"]
        pv = by_day[prev]["pay"] - by_day[prev]["refund"]
        if pv > 0 and lv < pv * (1 - W_DROP):
            warns.append(("单日净销售额", "环比跌 %.0f%%（%.0f → %.0f）" % ((1 - lv / pv) * 100, pv, lv),
                          "查渠道流量与前一日投放是否中断"))
    for s, p in prods.items():
        stock = int(fnum(p.get("库存")))
        if stock < W_LOW_STOCK:
            warns.append(("%s 库存" % s, "%d 件 < %d 件" % (stock, W_LOW_STOCK), "立即补货，暂停放量投放"))
    if any(o["状态"] == "部分退款" for o in orders):
        warns.append(("部分退款", "存在部分退款订单", "检查缺件或规格不符"))

    # ---------------- 输出 ----------------
    L = []
    L.append("# 运营日报 %s ~ %s\n" % (dates[0], dates[-1]))
    L.append("> 口径：GMV=实付金额合计；净销售额=GMV-退款；退款率=退款/GMV（按金额）；"
             "客单价=净销售额/成交用户数；ROI=GMV/推广费；贡献利润=实付-成本-平台5%-物流-推广-退款。\n")

    L.append("## 一句话结论\n")
    top = sku_rows[0] if sku_rows else None
    L.append("本期净销售额 %.0f 元（%d 单 / %d 位买家），贡献利润 %.0f 元，退款率 %.1f%%。"
             "利润主要来自 %s（贡献 %.0f 元，%.0f%%）。%s\n"
             % (net, n, len(buyers), total_contrib, rr * 100,
                top["商品名"] if top else "-", top["_contrib"] if top else 0,
                top["_rate"] * 100 if top else 0,
                "有 %d 条需要今天处理的预警。" % len(warns) if warns else "本期无预警。"))

    L.append("## 一、整体经营\n")
    L.append("| 指标 | 数值 |")
    L.append("| --- | --- |")
    L.append("| GMV | %.2f |" % pay)
    L.append("| 净销售额 | %.2f |" % net)
    L.append("| 订单数 | %d |" % n)
    L.append("| 成交买家数 | %d |" % len(buyers))
    L.append("| 客单价 | %.2f |" % (net / len(buyers) if buyers else 0))
    L.append("| 退款金额 | %.2f |" % refund)
    L.append("| 退款率 | %.1f%% |" % (rr * 100))
    L.append("| 推广费 | %.2f |" % ad)
    L.append("| ROI（GMV口径） | %.2f |" % roi)
    L.append("| 真实投产（贡献利润口径） | %.2f |" % real_roi)
    L.append("| 贡献利润合计 | %.2f |" % total_contrib)
    L.append("")

    L.append("## 二、平台表现\n")
    L.append("| 平台 | 订单 | GMV | 净额 | 退款率 | 客单价 |")
    L.append("| --- | --- | --- | --- | --- | --- |")
    for ch, v in sorted(by_ch.items(), key=lambda x: -x[1]["pay"]):
        L.append("| %s | %d | %.2f | %.2f | %.1f%% | %.2f |" % (
            ch, v["n"], v["pay"], v["pay"] - v["refund"],
            (v["refund"] / v["pay"] * 100 if v["pay"] else 0),
            (v["pay"] - v["refund"]) / v["n"] if v["n"] else 0))
    L.append("")

    L.append("## 三、商品表现\n")
    L.append("| SKU | 商品名 | 件数 | GMV | 退款率 | 推广费 | 贡献利润 | 贡献率 |")
    L.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in sku_rows:
        L.append("| %(SKU)s | %(商品名)s | %(件数)d | %(GMV)s | %(退款率)s | %(推广费)s | %(贡献利润)s | %(贡献率)s |"
                 % r)
    hot = [r for r in sku_rows if r["_rate"] >= 0.25]
    cold = [r for r in sku_rows if r["件数"] <= 2]
    L.append("")
    L.append("- 高贡献（继续推）：%s" % ("、".join(r["商品名"] for r in hot) or "无"))
    L.append("- 低销量（调整或下架）：%s" % ("、".join("%s(%d件)" % (r["商品名"], r["件数"]) for r in cold) or "无"))
    L.append("")

    L.append("## 四、流量与转化\n")
    L.append("> orders.csv 不含访客/点击/加购数据。要看转化率，需从平台后台导出"
             "「访客数、点击率、加购率、支付转化率」后并入本报表；当前只能给渠道结构。\n")
    L.append("| 渠道 | 订单 | GMV | 订单占比 |")
    L.append("| --- | --- | --- | --- |")
    for ch, v in sorted(by_ch.items(), key=lambda x: -x[1]["n"]):
        L.append("| %s | %d | %.2f | %.0f%% |" % (ch, v["n"], v["pay"], v["n"] * 100.0 / n if n else 0))
    L.append("")

    L.append("## 五、风险预警\n")
    if warns:
        L.append("| 项 | 触发值 | 建议动作 |")
        L.append("| --- | --- | --- |")
        for name, val, act in warns:
            L.append("| %s | %s | %s |" % (name, val, act))
    else:
        L.append("- 无（阈值：退款率 %.0f%%、单日环比跌 %.0f%%、待发货 %d 单、库存 %d 件、单品退款率 %.0f%%）"
                 % (W_REFUND_RATE * 100, W_DROP * 100, W_PENDING, W_LOW_STOCK, W_SKU_REFUND * 100))
    L.append("")

    L.append("## 六、今天要做的 3 件事\n")
    acts = []
    if warns:
        for name, val, act in warns[:3]:
            acts.append("**%s**（%s）→ %s" % (name, val, act))
    while len(acts) < 3:
        acts.append("补齐访客与转化数据，才能判断流量是否变成成交")
        acts.append("核对高贡献品的库存与补货周期，避免断货丢权重")
        acts.append("把本期新增的买家高频问题补进 data/faq.json")
        acts = acts[:3]
    for i, x in enumerate(acts[:3], 1):
        L.append("%d. %s" % (i, x))
    L.append("")

    L.append("## 附：订单状态分布\n")
    for k, v in status.items():
        L.append("- %s：%d" % (k, v))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(L))

    print("\n".join(L[:22]))
    print("\n...\n")
    print("完整日报: %s" % OUT)
    print("预警 %d 条 ｜ 贡献利润 %.2f ｜ 真实投产 %.2f" % (len(warns), total_contrib, real_roi))


if __name__ == "__main__":
    main()
