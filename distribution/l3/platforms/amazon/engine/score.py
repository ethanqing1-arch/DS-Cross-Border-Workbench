#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
跨境选品打分引擎 v1.0
口径来源：SKILL_SPEC.md 第 3/4 节（数据字典 + 三层利润 + 四维打分 + 硬红线）
用法：
    python3 engine/score.py                       # 用 data/candidates_sample.csv
    python3 engine/score.py --input data/x.csv --top 5 --category 宠物
    python3 engine/score.py --fx 7.15 --no-excel
输出：out/<run_id>/{选品打分.csv, 选品报告.md, 选品看板.xlsx, 决策卡.md}
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

# ---------------------------------------------------------------- 常量（写死，不得改）
FX_DEFAULT = 7.15
WEIGHTS = {"demand": 0.25, "competition": 0.25, "profit": 0.30, "risk": 0.20}
RED_LINE = {
    "gross_margin_min": 0.30,      # 毛利率 < 30% 不进付费测款
    "contrib_margin_min": 0.08,    # 贡献利润率 < 8% 不做付费主推
    "contrib_abs_min": 3.0,        # 贡献利润 < 3 USD/件 不测
    "ip_risk_max": 7.0,            # 侵权风险 >= 7 直接否
    "supply_min": 4.0,             # 供应稳定性 < 4 直接否
    "d_share_max": 0.30,           # D 级数据占比 > 30% 结论降档
}
VERDICT_GO, VERDICT_WATCH, VERDICT_DROP = 60.0, 48.0, 0.0
TIER = [(0.18, "利润款"), (0.08, "引流款"), (-9.9, "清仓款")]

FIELDS = [
    "sku", "category", "product", "cogs_cny", "price_usd", "inbound_usd",
    "referral_rate", "fba_fee_usd", "ad_share", "return_rate", "return_loss_ratio",
    "tariff_rate", "monthly_search_volume", "competitor_count", "top_review_count",
    "top10_share", "supply_stability", "differentiation_score", "ip_risk",
    "cert_required", "has_cert", "d_share",
]
DEFAULTS = {
    "referral_rate": 0.15, "return_loss_ratio": 0.15, "tariff_rate": 0.25,
    "cert_required": 0.0, "has_cert": 1.0, "d_share": 0.1, "ip_risk": 3.0,
    "supply_stability": 7.0, "differentiation_score": 5.0, "top10_share": 0.5,
}


@dataclass
class Row:
    raw: dict[str, str]
    m: dict[str, Any] = field(default_factory=dict)
    flags: list[str] = field(default_factory=list)
    scores: dict[str, float] = field(default_factory=dict)
    total: float = 0.0
    verdict: str = ""
    tier: str = ""


def num(raw: dict[str, str], key: str, default: float | None = None) -> float:
    v = (raw.get(key) or "").strip()
    if v == "":
        if default is None:
            raise ValueError(f"字段 {key} 缺失（sku={raw.get('sku')}）")
        return float(default)
    return float(v.replace("%", "").replace(",", "")) / (100 if "%" in v else 1)


def compute(row: Row, fx: float) -> None:
    r, m = row.raw, row.m
    price = num(r, "price_usd")
    cogs = num(r, "cogs_cny") / fx
    inbound = num(r, "inbound_usd", 0)
    # 关税基数是申报货值（≈采购价），不是售价
    tariff = cogs * num(r, "tariff_rate", DEFAULTS["tariff_rate"])
    referral = price * num(r, "referral_rate", DEFAULTS["referral_rate"])
    fba = num(r, "fba_fee_usd", 0)
    ad = price * num(r, "ad_share", 0.3)
    ret_rate = num(r, "return_rate", 0.08)
    ret_loss = price * ret_rate * num(r, "return_loss_ratio", DEFAULTS["return_loss_ratio"])

    gross = price - cogs - inbound - tariff
    fee_fulfil = referral + fba
    contrib = gross - fee_fulfil - ad - ret_loss
    gross_margin = gross / price
    contrib_margin = contrib / price
    # 盈亏平衡售价：contrib=0 → P* = (cogs×(1+关税)+头程+FBA) / (1-佣金-ad_share-退货率×损耗)
    _t = num(r, "tariff_rate", 0.25)
    _den = (1 - num(r, "referral_rate", 0.15) - num(r, "ad_share", 0.3)
            - ret_rate * num(r, "return_loss_ratio", 0.15))
    breakeven_price = (cogs * (1 + _t) + inbound + fba) / _den if _den > 0.05 else float("nan")

    m.update(dict(
        cogs_usd=cogs, price=price, inbound=inbound, tariff=tariff, referral=referral,
        fba=fba, ad=ad, return_loss=ret_loss, gross=gross, fee_fulfil=fee_fulfil,
        contrib=contrib, gross_margin=gross_margin, contrib_margin=contrib_margin,
        breakeven_price=breakeven_price,
        monthly_search_volume=num(r, "monthly_search_volume", 5000),
        competitor_count=num(r, "competitor_count", 800),
        top_review_count=num(r, "top_review_count", 800),
        top10_share=num(r, "top10_share", 0.5),
        supply=num(r, "supply_stability", 7),
        diff=num(r, "differentiation_score", 5),
        ip=num(r, "ip_risk", 3),
        return_rate=ret_rate,
        cert=int(num(r, "cert_required", 0)),
        has_cert=int(num(r, "has_cert", 1)),
        d_share=num(r, "d_share", 0.1),
    ))

    # 硬红线
    f = row.flags
    if gross_margin < RED_LINE["gross_margin_min"]:
        f.append(f"R1 毛利率 {gross_margin:.1%} < 30%")
    if contrib_margin < RED_LINE["contrib_margin_min"]:
        f.append(f"R2 贡献利润率 {contrib_margin:.1%} < 8%")
    if contrib < RED_LINE["contrib_abs_min"]:
        f.append(f"R3 贡献利润 {contrib:.2f} USD < 3 USD")
    if m["ip"] >= RED_LINE["ip_risk_max"]:
        f.append(f"R4 侵权风险 {m['ip']:.0f}/10 ≥ 7")
    if m["cert"] == 1 and m["has_cert"] == 0:
        f.append("R4 需认证/资质但卖家不具备")
    if m["supply"] < RED_LINE["supply_min"]:
        f.append(f"R5 供应稳定性 {m['supply']:.1f}/10 < 4")


def _clamp(x: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, x))


def _lin(v: float, at_zero: float, at_hundred: float) -> float:
    """绝对锚定线性映射（跨批次可比，不用 min-max，避免每批必出一个 100 分）"""
    if at_hundred == at_zero:
        return 50.0
    return _clamp((v - at_zero) / (at_hundred - at_zero) * 100.0)


def score_all(rows: list[Row]) -> None:
    for r in rows:
        m = r.m
        # 需求：月搜索 1k→0，500k→100（对数刻度）
        demand = _lin(math.log10(max(1.0, m["monthly_search_volume"])), 3.0, 5.7)
        # 竞争压力 = 密度50% + 评论壁垒25% + 垄断度25%，再取反
        density = _lin(math.log10(max(1.0, m["competitor_count"])), 1.0, 4.0)      # 10 → 10000
        barrier = _lin(math.log10(max(1.0, m["top_review_count"])), 1.5, 5.0)       # 30 → 100k
        concentration = _clamp(m["top10_share"] * 100)
        competition = 100.0 - (0.50 * density + 0.25 * barrier + 0.25 * concentration)
        # 盈利：绝对额50% + 贡献率30% + 毛利率20%
        p_abs = _lin(math.log1p(max(0.0, m["contrib"])), 0.0, math.log1p(12.0))
        p_margin = _clamp(m["contrib_margin"] / 0.35 * 100)
        p_gross = _clamp(m["gross_margin"] / 0.80 * 100)
        profit = 0.50 * p_abs + 0.30 * p_margin + 0.20 * p_gross
        # 风险：退货30 + 供应30 + 差异化25 + 侵权15
        risk = (30.0 * (1 - m["return_rate"]) + 30.0 * (m["supply"] / 10)
                + 25.0 * (m["diff"] / 10) + 15.0 * (1 - m["ip"] / 10))

        r.scores = {"需求强度": round(demand, 1), "竞争压力": round(competition, 1),
                    "盈利": round(profit, 1), "风险": round(_clamp(risk), 1)}
        r.total = round(
            r.scores["需求强度"] * WEIGHTS["demand"]
            + r.scores["竞争压力"] * WEIGHTS["competition"]
            + r.scores["盈利"] * WEIGHTS["profit"]
            + r.scores["风险"] * WEIGHTS["risk"], 1)

        # 结论：红线 > 分数 > 数据等级
        hard = [x for x in r.flags if not x.startswith("R1 ")]
        if hard:
            r.verdict = "放弃"
        elif r.total >= VERDICT_GO:
            r.verdict = "上架测试"
        elif r.total >= VERDICT_WATCH:
            r.verdict = "观察"
        else:
            r.verdict = "放弃"
        if r.verdict == "上架测试" and r.flags:      # R1 软红线：降为观察
            r.verdict = "观察"
        if r.verdict == "上架测试" and m["d_share"] > RED_LINE["d_share_max"]:
            r.verdict = "观察"
        if m["d_share"] > RED_LINE["d_share_max"] and r.verdict == "观察":
            r.verdict = "放弃"
        # SKU 分层（五档，见 SPEC 4.5）
        if r.verdict == "放弃" or r.total < VERDICT_WATCH:
            r.tier = "不做/清仓"
        elif r.total < VERDICT_GO:
            r.tier = "观察款"
        elif m["contrib_margin"] >= 0.20:
            r.tier = "利润款"
        elif m["contrib_margin"] >= 0.08 and r.scores["需求强度"] >= 70:
            r.tier = "引流款"
        else:
            r.tier = "常规款"


def run_id_for(cat: str) -> str:
    slug = re.sub(r"[^\w\u4e00-\u9fa5]+", "-", cat).strip("-") or "all"
    return f"{datetime.now():%Y%m%d-%H%M}-{slug}"


def write_csv(rows: list[Row], path: str) -> None:
    """列名与 SKILL_SPEC 4.6 逐字一致：原始字段 + 英文 snake_case 计算列。"""
    computed = ["gross_profit_usd", "gross_margin", "contribution_profit_usd",
                "contribution_margin", "breakeven_price_usd", "score_demand",
                "score_competition", "score_profit", "score_risk", "score_total",
                "verdict", "sku_tier", "redline_flags", "evidence_grade"]
    with open(path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(FIELDS + computed)
        for r in sorted(rows, key=lambda x: -x.total):
            m = r.m
            w.writerow([r.raw.get(k, "") for k in FIELDS] + [
                f"{m['gross']:.2f}", f"{m['gross_margin']:.4f}",
                f"{m['contrib']:.2f}", f"{m['contrib_margin']:.4f}",
                ("nan" if math.isnan(m["breakeven_price"]) else f"{m['breakeven_price']:.2f}"),
                r.scores["需求强度"], r.scores["竞争压力"], r.scores["盈利"], r.scores["风险"],
                r.total, r.verdict, r.tier, "|".join(r.flags) or "PASS",
                r.raw.get("evidence_grade", "B"),
            ])


def write_report(rows: list[Row], path: str, rid: str, fx: float, src: str, label: str = "") -> None:
    rows = sorted(rows, key=lambda x: -x.total)
    go = [r for r in rows if r.verdict == "上架测试"]
    watch = [r for r in rows if r.verdict == "观察"]
    drop = [r for r in rows if r.verdict == "放弃"]
    L: list[str] = []
    A = L.append
    A(f"# 选品决策报告 · {label or (rows[0].raw['category'] if rows else '')}")
    A("")
    A(f"**结论：{len(go)} 可做 / {len(watch)} 观察 / {len(drop)} 放弃（共 {len(rows)} 个候选）**")
    A("")
    A(f"- 运行号：`{rid}`　数据源：`{src}`　汇率：1 USD = {fx} CNY")
    A(f"- 口径：三层利润 + 四维打分（需求25/竞争25/盈利30/风险20），红线一票否决")
    A("- 证据等级：A 实测 / B 抓取 / C 估算 / D 假设；D>30% 强制降档")
    A("")
    A("## 一、总览")
    A("")
    A("| 排名 | SKU | 商品 | 总分 | 贡献利润 | 贡献率 | 结论 | 分层 |")
    A("|---:|---|---|---:|---:|---:|---|---|")
    for i, r in enumerate(rows, 1):
        A(f"| {i} | {r.raw['sku']} | {r.raw['product']} | {r.total:.1f} | "
          f"{r.m['contrib']:.2f} | {r.m['contrib_margin']:.1%} | {r.verdict} | {r.tier} |")
    A("")
    A("## 二、可做（上架测试）")
    A("")
    if not go:
        A("本轮无品达到测试线。见第四节「放弃原因」中的最高分品，补齐证据后重跑。")
    for r in go:
        m = r.m
        A(f"### {r.raw['product']}（{r.raw['sku']}）· {r.total:.1f} 分 · {r.tier}")
        A("")
        A(f"- 利润：售价 {m['price']:.2f}，采购 {m['cogs_usd']:.2f}，头程 {m['inbound']:.2f}，"
          f"关税 {m['tariff']:.2f}，佣金+FBA {m['fee_fulfil']:.2f}，推广 {m['ad']:.2f}，"
          f"退货 {m['return_loss']:.2f} → **贡献利润 {m['contrib']:.2f}（{m['contrib_margin']:.1%}）**")
        A(f"- 四维：需求 {r.scores['需求强度']} / 竞争 {r.scores['竞争压力']} / "
          f"盈利 {r.scores['盈利']} / 风险 {r.scores['风险']}")
        A(f"- 市场：月搜 {m['monthly_search_volume']:.0f}，在售 {m['competitor_count']:.0f}，"
          f"首页最高评论 {m['top_review_count']:.0f}，垄断度 {m['top10_share']:.0%}")
        if r.flags:
            A(f"- 待整改：{'；'.join(r.flags)}")
        A(f"- 动作：首单 100–200 件；定价锚点 {m['breakeven_price']:.2f} 以上；"
          f"广告预算按 ad_share ≤ {num(r.raw,'ad_share',0.3):.0%} 控；14 天看 CVR 与退货率，"
          f"贡献率跌破 8% 立即停投。")
        A("")
    A("## 三、观察（小批量）")
    A("")
    if not watch:
        A("无。")
    for r in watch:
        A(f"- **{r.raw['product']}（{r.raw['sku']}）{r.total:.1f} 分**：贡献率 "
          f"{r.m['contrib_margin']:.1%}；{'缺口：' + '；'.join(r.flags) if r.flags else '数据等级不足，需补 A/B 级证据'}"
          f" → 动作：先做 1 版差异化样品 + 50 件试销，不动广告。")
    A("")
    A("## 四、放弃与原因")
    A("")
    if not drop:
        A("无。")
    for r in drop:
        A(f"- **{r.raw['product']}（{r.raw['sku']}）{r.total:.1f} 分**："
          f"{'；'.join(r.flags) if r.flags else f'总分低于 48，四维中最弱项为' + min(r.scores, key=r.scores.get)}")
    A("")
    A("## 五、今天就要做的 3 件事")
    A("")
    if go:
        best = go[0]
        A(f"1. 给 {best.raw['product']} 下 3 家 1688 打样单（含税含运报价），3 天内回收 BOM 与 MOQ。")
        A(f"2. 用 {best.raw['product']} 的 Top20 差评做差异化命题，出 1 版主图 brief。")
        A("3. 把观察档的品补 A 级数据（后台/SP-API 导出），本周五重跑打分。")
    else:
        A("1. 本轮无测试品：从放弃档里挑总分最高者，补 D 级字段（退货率/广告占比）。")
        A("2. 换赛道：用关键词采集重跑 3 个相邻细分，避免同质竞争。")
        A("3. 复盘口径：确认 FX、FBA 分段、ad_share 是否用了最新值。")
    A("")
    A("---")
    A("口径与阈值见 `SKILL_SPEC.md` 第 4 节；明细见 `选品打分.csv`，看板见 `选品看板.xlsx`。")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


def write_decision_card(rows: list[Row], path: str) -> None:
    rows = sorted(rows, key=lambda x: -x.total)
    if not rows:
        return
    r = rows[0]
    m = r.m
    L = [
        f"# Go / No-Go 决策卡 · {r.raw['product']}（{r.raw['sku']}）",
        "",
        f"**决策：{'GO — 进入上架测试' if r.verdict == '上架测试' else 'NO-GO — ' + r.verdict}**",
        "",
        "| 项 | 值 | 红线 | 是否通过 |",
        "|---|---:|---:|---|",
        f"| 总分 | {r.total:.1f} | ≥60 | {'✅' if r.total >= 60 else '❌'} |",
        f"| 毛利率 | {m['gross_margin']:.1%} | ≥30% | {'✅' if m['gross_margin'] >= .3 else '❌'} |",
        f"| 贡献利润率 | {m['contrib_margin']:.1%} | ≥8% | {'✅' if m['contrib_margin'] >= .08 else '❌'} |",
        f"| 单件贡献利润 | {m['contrib']:.2f} USD | ≥3 USD | {'✅' if m['contrib'] >= 3 else '❌'} |",
        f"| 侵权风险 | {m['ip']:.0f}/10 | <7 | {'✅' if m['ip'] < 7 else '❌'} |",
        f"| 供应稳定性 | {m['supply']:.1f}/10 | ≥4 | {'✅' if m['supply'] >= 4 else '❌'} |",
        "",
        "## 投入上限",
        f"- 首单：200 件 × {m['cogs_usd']:.2f} USD ≈ {200*m['cogs_usd']:.0f} USD 货值"
        f"（+头程 {200*m['inbound']:.0f} USD）",
        f"- 广告：首单周期按 {num(r.raw,'ad_share',0.3):.0%} ad_share × 200 件测算 ≈ "
        f"{m['price']*num(r.raw,'ad_share',0.3)*200:.0f} USD，硬上限 "
        f"{m['price']*num(r.raw,'ad_share',0.3)*1.3*200:.0f} USD",
        "- 样品+拍摄+认证：≤ 800 USD",
        "",
        "## 验证指标（14 天）",
        f"- CVR ≥ 8%，退货率 ≤ {m['return_rate']:.0%}，ACOS ≤ 35%",
        "- 贡献利润率不得跌破 8%：跌破即停投",
        "",
        "## 止损线",
        "- 30 天累计贡献利润为负 → 清仓退出",
        "- 连续 7 天 CVR < 5% → 换主图或退场",
        "",
        f"复盘日期：{(datetime.now()).strftime('%Y-%m-%d')} + 30 天",
    ]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(L))


def write_xlsx(rows: list[Row], path: str, rid: str) -> None:
    try:
        from openpyxl import Workbook
        from openpyxl.styles import Alignment, Font, PatternFill
        from openpyxl.utils import get_column_letter
    except ImportError:
        print("! openpyxl 缺失，跳过 Excel", file=sys.stderr)
        return
    rows = sorted(rows, key=lambda x: -x.total)
    wb = Workbook()
    head_fill = PatternFill("solid", fgColor="1F3A5F")
    head_font = Font(color="FFFFFF", bold=True, size=10)

    def sheet(title, headers, data, widths=None):
        ws = wb.create_sheet(title)
        ws.append(headers)
        for c in range(1, len(headers) + 1):
            cell = ws.cell(1, c)
            cell.fill, cell.font = head_fill, head_font
            cell.alignment = Alignment(horizontal="center", vertical="center")
        for row in data:
            ws.append(row)
        ws.freeze_panes = "A2"
        for i, h in enumerate(headers, 1):
            ws.column_dimensions[get_column_letter(i)].width = (
                widths[i - 1] if widths and i - 1 < len(widths) else max(10, min(28, len(str(h)) * 2 + 4))
            )
        ws.auto_filter.ref = ws.dimensions
        return ws

    wb.remove(wb.active)
    # 1 总览
    ws = sheet("总览", ["SKU", "商品", "品类", "总分", "结论", "分层", "贡献利润", "贡献率", "红线"],
               [[r.raw["sku"], r.raw["product"], r.raw["category"], r.total, r.verdict, r.tier,
                 round(r.m["contrib"], 2), round(r.m["contrib_margin"], 4), "；".join(r.flags) or "无"]
                for r in rows], [12, 26, 10, 8, 10, 10, 12, 10, 40])
    for i, r in enumerate(rows, 2):
        color = {"上架测试": "C6EFCE", "观察": "FFEB9C", "放弃": "FFC7CE"}[r.verdict]
        ws.cell(i, 5).fill = PatternFill("solid", fgColor=color)
        ws.cell(i, 8).number_format = "0.0%"
    # 2 打分明细
    sheet("打分明细", ["SKU", "需求强度", "竞争压力", "盈利", "风险", "总分"],
          [[r.raw["sku"], r.scores["需求强度"], r.scores["竞争压力"], r.scores["盈利"],
            r.scores["风险"], r.total] for r in rows])
    # 3 利润瀑布
    sheet("利润瀑布", ["SKU", "售价", "采购", "头程", "关税", "佣金", "FBA", "推广", "退货损耗",
                     "贡献利润", "贡献率", "毛利率", "盈亏平衡售价"],
          [[r.raw["sku"], round(r.m["price"], 2), round(r.m["cogs_usd"], 2), round(r.m["inbound"], 2),
            round(r.m["tariff"], 2), round(r.m["referral"], 2), round(r.m["fba"], 2), round(r.m["ad"], 2),
            round(r.m["return_loss"], 2), round(r.m["contrib"], 2),
            round(r.m["contrib_margin"], 4), round(r.m["gross_margin"], 4),
            round(r.m["breakeven_price"], 2)] for r in rows])
    # 4 市场
    sheet("市场与竞争", ["SKU", "月搜索量", "在售竞品", "首页最高评论", "垄断度", "供应商稳定性", "差异化", "侵权风险"],
          [[r.raw["sku"], r.m["monthly_search_volume"], r.m["competitor_count"],
            r.m["top_review_count"], r.m["top10_share"], r.m["supply"], r.m["diff"], r.m["ip"]]
           for r in rows])
    # 5 动作清单
    sheet("动作清单", ["SKU", "结论", "下一步动作", "负责人", "截止日"],
          [[r.raw["sku"], r.verdict,
            ("下单打样 + 出主图 brief" if r.verdict == "上架测试" else
             "补 A 级数据后重跑" if r.verdict == "观察" else "归档，不再投入"),
            "", ""] for r in rows], [12, 10, 34, 10, 12])
    # 6 口径
    sheet("口径说明", ["项", "值"], [
        ["运行号", rid],
        ["权重", "需求25% / 竞争25% / 盈利30% / 风险20%"],
        ["结论分档", "≥60 上架测试 / 48–59 观察 / <48 放弃"],
        ["红线", "毛利率<30%；贡献率<8%；单件贡献<3USD；侵权≥7；供应<4；需认证无资质"],
        ["D级占比", ">30% 结论强制降档"],
        ["利润公式", "贡献=售价-采购-头程-关税-(佣金+FBA)-推广-退货损耗"],
    ], [14, 72])
    wb.save(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--input", default=os.path.join(here, "data", "candidates_sample.csv"))
    ap.add_argument("--out", default=os.path.join(here, "out"))
    ap.add_argument("--fx", type=float, default=FX_DEFAULT)
    ap.add_argument("--top", type=int, default=0)
    ap.add_argument("--category", default="")
    ap.add_argument("--no-excel", action="store_true")
    a = ap.parse_args()

    with open(a.input, encoding="utf-8-sig") as fh:
        raw_rows = [dict(x) for x in csv.DictReader(fh)]
    if a.category:
        raw_rows = [x for x in raw_rows if a.category in x.get("category", "")]
    if not raw_rows:
        print("没有候选数据", file=sys.stderr)
        return 2

    rows = [Row(raw=x) for x in raw_rows]
    for r in rows:
        compute(r, a.fx)
    score_all(rows)
    if a.top:
        go = [r for r in rows if r.verdict == "上架测试"]
        rows = (go or sorted(rows, key=lambda x: -x.total))[: a.top]

    rid = run_id_for(a.category or "all")
    outdir = os.path.join(a.out, rid)
    os.makedirs(outdir, exist_ok=True)

    write_csv(rows, os.path.join(outdir, "选品打分.csv"))
    write_report(rows, os.path.join(outdir, "选品报告.md"), rid, a.fx,
                 os.path.basename(a.input), a.category or "全量候选")
    write_decision_card(rows, os.path.join(outdir, "决策卡.md"))
    if not a.no_excel:
        write_xlsx(rows, os.path.join(outdir, "选品看板.xlsx"), rid)
    with open(os.path.join(outdir, "run_meta.json"), "w", encoding="utf-8") as fh:
        json.dump({"run_id": rid, "input": a.input, "fx": a.fx, "n": len(rows),
                   "verdicts": {v: sum(1 for r in rows if r.verdict == v)
                                for v in ("上架测试", "观察", "放弃")}},
                  fh, ensure_ascii=False, indent=2)

    go = [r for r in rows if r.verdict == "上架测试"]
    watch = [r for r in rows if r.verdict == "观察"]
    drop = [r for r in rows if r.verdict == "放弃"]
    print(f"结论：{len(go)} 可做 / {len(watch)} 观察 / {len(drop)} 放弃（共 {len(rows)} 个候选）")
    for r in sorted(rows, key=lambda x: -x.total):
        print(f"  {r.total:5.1f}  {r.verdict:4s}  {r.tier:4s}  {r.raw['sku']:8s} "
              f"{r.raw['product'][:18]:18s} 贡献 {r.m['contrib']:6.2f} ({r.m['contrib_margin']:5.1%})"
              + (f"  红线:{'；'.join(r.flags)}" if r.flags else ""))
    print(f"输出：{outdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
