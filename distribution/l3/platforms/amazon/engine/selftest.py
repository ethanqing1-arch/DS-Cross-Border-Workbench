#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""引擎自检：验证口径与实现一致（CI 可跑）。
用法：python3 engine/selftest.py
"""
from __future__ import annotations

import csv
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score as S  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILS: list[str] = []
CHECKS = 0


def check(cond: bool, msg: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(msg)


def load() -> list[S.Row]:
    with open(os.path.join(HERE, "data", "candidates_sample.csv"), encoding="utf-8-sig") as fh:
        rows = [S.Row(raw=dict(x)) for x in csv.DictReader(fh)]
    for r in rows:
        S.compute(r, S.FX_DEFAULT)
    S.score_all(rows)
    return rows


def golden() -> None:
    """金标回归：数字取自 profit-model/references/formula.md §5 算例，
    引擎与文档两份实现必须给出同一结果，否则口径已经分叉。"""
    raw = {
        "sku": "GOLD-001", "category": "金标", "product": "回归算例",
        "cogs_cny": "38", "price_usd": "34.99", "inbound_usd": "2.10",
        "referral_rate": "0.15", "fba_fee_usd": "4.75", "ad_share": "0.28",
        "return_rate": "0.06", "return_loss_ratio": "1.0", "tariff_rate": "0.25",
        "monthly_search_volume": "20000", "competitor_count": "1200",
        "top_review_count": "4000", "top10_share": "0.5",
        "supply_stability": "7", "differentiation_score": "6", "ip_risk": "3",
        "cert_required": "0", "has_cert": "1", "d_share": "0.2",
    }
    r = S.Row(raw=raw)
    S.compute(r, 7.15)
    S.score_all([r])
    check(abs(r.m["contrib"] - 4.3515) < 0.002,
          f"金标贡献利润 {r.m['contrib']:.4f} ≠ 4.3515（与 formula.md 不一致）")
    check(abs(r.m["contrib_margin"] - 0.1244) < 0.0005,
          f"金标贡献率 {r.m['contrib_margin']:.4%} ≠ 12.44%")
    check(abs(r.m["gross_margin"] - 0.7501) < 0.0005,
          f"金标毛利率 {r.m['gross_margin']:.4%} ≠ 75.01%")
    check(abs(r.m["breakeven_price"] - 26.46) < 0.02,
          f"金标盈亏平衡价 {r.m['breakeven_price']:.2f} ≠ 26.46")
    # 最低售价（红线 R3：单件贡献 ≥ 3 USD）：(F + 3) / k
    k = 1 - 0.15 - 0.28 - 0.06
    F = r.m["cogs_usd"] * 1.25 + 2.10 + 4.75
    check(abs((F + 3) / k - 32.34) < 0.03,
          f"金标最低售价 {(F + 3) / k:.2f} ≠ 32.34")


def main() -> int:
    rows = load()
    check(bool(rows), "样本为空")

    # 1) 权重和为 1
    check(abs(sum(S.WEIGHTS.values()) - 1.0) < 1e-9, "四维权重之和 ≠ 1")

    for r in rows:
        m, raw = r.m, r.raw
        # 2) 利润瀑布可复算
        recomputed = (m["price"] - m["cogs_usd"] - m["inbound"] - m["tariff"]
                      - m["referral"] - m["fba"] - m["ad"] - m["return_loss"])
        check(abs(recomputed - m["contrib"]) < 1e-9,
              f"{raw['sku']} 贡献利润不可复算: {recomputed:.6f} vs {m['contrib']:.6f}")

        # 3) 关税基数是采购价，不是售价
        expect_tariff = m["cogs_usd"] * float(raw["tariff_rate"])
        check(abs(m["tariff"] - expect_tariff) < 1e-9,
              f"{raw['sku']} 关税基数错（应按 cogs_usd）")

        # 4) 分数区间
        for k, v in r.scores.items():
            check(-0.05 <= v <= 100.05, f"{raw['sku']} 维度 {k} 越界: {v}")

        # 5) 总分可复算
        t = (r.scores["需求强度"] * 0.25 + r.scores["竞争压力"] * 0.25
             + r.scores["盈利"] * 0.30 + r.scores["风险"] * 0.20)
        check(abs(t - r.total) < 0.15, f"{raw['sku']} 总分不可复算: {t:.2f} vs {r.total}")

        # 6) 硬红线 → 放弃
        hard = [x for x in r.flags if not x.startswith("R1 ")]
        if hard:
            check(r.verdict == "放弃", f"{raw['sku']} 有硬红线却给 {r.verdict}: {hard}")

        # 7) D 级占比超限 → 不得上架测试
        if m["d_share"] > S.RED_LINE["d_share_max"]:
            check(r.verdict != "上架测试", f"{raw['sku']} D级占比 {m['d_share']} 仍给上架测试")

        # 8) 分档与分数一致（无红线时）
        if not hard:
            if r.total >= 60:
                check(r.verdict in ("上架测试", "观察"), f"{raw['sku']} 高分未进测试/观察")
            elif r.total >= 48:
                check(r.verdict in ("观察", "放弃"), f"{raw['sku']} 中分处理异常")

        # 9) 盈亏平衡价：在该价位贡献利润应为 0
        p = m["breakeven_price"]
        if not math.isnan(p):
            c = (p - m["cogs_usd"] - m["inbound"] - m["cogs_usd"] * float(raw["tariff_rate"])
                 - p * float(raw["referral_rate"]) - m["fba"] - p * float(raw["ad_share"])
                 - p * float(raw["return_rate"]) * float(raw["return_loss_ratio"]))
            check(abs(c) < 0.02, f"{raw['sku']} 盈亏平衡价 {p:.2f} 处贡献 {c:.4f} ≠ 0")

        # 10) SKU 分层与五档规则一致
        if r.verdict == "放弃" or r.total < 48:
            expect_tier = "不做/清仓"
        elif r.total < 60:
            expect_tier = "观察款"
        elif m["contrib_margin"] >= 0.20:
            expect_tier = "利润款"
        elif m["contrib_margin"] >= 0.08 and r.scores["需求强度"] >= 70:
            expect_tier = "引流款"
        else:
            expect_tier = "常规款"
        check(r.tier == expect_tier, f"{raw['sku']} 分层错: {r.tier} vs {expect_tier}")

    golden()

    print(f"自检 {CHECKS} 项断言，{len(rows)} 个样本")
    if FAILS:
        print(f"✗ 失败 {len(FAILS)} 项：")
        for f in FAILS:
            print("  -", f)
        return 1
    print("✓ 全部通过：利润瀑布可复算、关税基数为采购价、总分可复算、红线一票否决、"
          "D级降档生效、盈亏平衡价归零、分层一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
