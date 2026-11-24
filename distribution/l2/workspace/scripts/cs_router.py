#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""客服分流：意图识别 + 「情-事-案-收」四段话术组装 + 风险转人工 + 工单分类 + 巡检清单。

话术结构（来自实战复盘）：
    情  先接情绪，别一上来丢条款
    事  中性确认事实，不指责
    案  给 1-2 个具体可执行选项
    收  主动收尾，约定时间点，留后路

用法:
    python3 scripts/cs_router.py
    python3 scripts/cs_router.py --file data/messages.csv
"""
import argparse
import csv
import json
import os
import sys
from collections import Counter

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAQ = os.path.join(BASE, "data", "faq.json")
MSG = os.path.join(BASE, "data", "messages.csv")
OUT = os.path.join(BASE, "out", "客服处理.csv")
PATROL = os.path.join(BASE, "out", "店铺巡检清单.md")

SMALL_REFUND = 50.0  # 仅退款直接同意的金额线

# 情绪类意图 → 共情开场
EMPATHY = {
    "aftersale": "这个情况确实让人着急，给您添麻烦了。",
    "logistics": "等这么久确实着急，我理解。",
    "return": "理解您的心情，咱们按最省事的方式来。",
    "bargain": "谢谢您直接说，我帮您想想办法。",
}
# 需要先确认事实的意图
# 话术库里已经含"确认事实"的一律不再重复追加
FACT = {}
# 收尾句按优先级
CLOSE = {
    "高": "我今天下班前给您明确结果，期间有问题直接找我。",
    "中": "我这边今天内跟进，有进展第一时间告诉您。",
    "低": "您先看看，有问题随时找我。",
}
# 意图 → 工单类型
TICKET = {
    "aftersale": "质量问题", "转人工-风险": "投诉", "return": "售后",
    "logistics": "物流", "ship_time": "物流", "address": "物流",
    "price": "价格", "bargain": "价格", "coupon": "价格", "wholesale": "价格",
    "availability": "咨询", "size": "咨询", "material": "咨询", "color": "咨询",
    "compat": "咨询", "compare": "咨询", "detail_effect": "咨询",
    "accessories": "咨询", "invoice": "咨询", "praise": "评价", "fallback": "其他",
}


def load_faq(path):
    if not os.path.exists(path):
        sys.exit("缺少话术库: %s" % path)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_msgs(path):
    if not os.path.exists(path):
        sys.exit("缺少消息文件: %s" % path)
    with open(path, newline="", encoding="utf-8-sig") as f:
        return [r for r in csv.DictReader(f) if (r.get("消息") or "").strip()]


def fnum(v):
    try:
        return float(str(v).strip() or 0)
    except ValueError:
        return 0.0


def classify(text, faq):
    hits = [kw for kw in faq["escalate"]["keywords"] if kw in text]
    if hits:
        return {"intent": "转人工-风险", "name": "风险升级", "reply": faq["escalate"]["reply"],
                "priority": faq["escalate"]["priority"], "hit": "/".join(hits)}
    best, best_hits = None, 0
    for it in faq["intents"]:
        n = sum(1 for kw in it["keywords"] if kw in text)
        if n > best_hits:
            best, best_hits = it, n
    if best:
        return {"intent": best["id"], "name": best["name"], "reply": best["reply"],
                "priority": best["priority"], "hit": ""}
    return {"intent": "fallback", "name": "未命中", "reply": faq["fallback"]["reply"],
            "priority": faq["fallback"]["priority"], "hit": ""}


def compose(text, r, amount):
    """按 情-事-案-收 组装回复。"""
    parts = []
    emp = EMPATHY.get(r["intent"])
    if emp:
        parts.append(emp)
    fact = FACT.get(r["intent"])
    if fact:
        parts.append(fact)
    parts.append(r["reply"])
    parts.append(CLOSE.get(r["priority"], CLOSE["低"]))
    return "\n".join(parts)


def advice(text, r, amount):
    """在话术之外给人工的处理建议。"""
    tips = []
    if ("仅退款" in text) or ("退款" in text and "不退货" in text):
        if amount and amount < SMALL_REFUND:
            tips.append("金额 %.2f < %.0f 元，走流程成本高于货值，直接同意" % (amount, SMALL_REFUND))
        else:
            tips.append("金额 %.2f ≥ %.0f 元，要求提供开箱视频/照片后再处理" % (amount, SMALL_REFUND))
    if r["intent"] == "转人工-风险":
        tips.append("30 分钟内人工接手，禁止发送自动回复")
        tips.append("先解决问题，再礼貌询问是否愿意更新评价；不得要求删评改评")
    if r["intent"] == "aftersale":
        tips.append("补发或退款二选一，不让客户寄回")
    if r["intent"] == "address":
        tips.append("未发货直接改；已发货联系快递改派")
    if r["intent"] == "ship_time":
        tips.append("核对订单是否超过 48h，超时主动补偿运费券")
    return "；".join(tips)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=MSG)
    a = ap.parse_args()

    faq = load_faq(FAQ)
    msgs = load_msgs(a.file)

    rows, counter, ticket, miss = [], Counter(), Counter(), []
    for m in msgs:
        text = m["消息"]
        amount = fnum(m.get("订单金额"))
        r = classify(text, faq)
        counter[r["name"]] += 1
        ttype = TICKET.get(r["intent"], "其他")
        ticket[ttype] += 1
        if r["intent"] == "fallback":
            miss.append(text)
        to_human = "是" if (r["intent"] in ("转人工-风险", "fallback") or r["priority"] == "高") else "否"
        rows.append({
            "时间": m.get("时间", ""),
            "买家ID": m.get("买家ID", ""),
            "订单金额": "%.2f" % amount if amount else "",
            "消息": text,
            "意图": r["name"],
            "工单类型": ttype,
            "优先级": r["priority"],
            "建议回复": compose(text, r, amount),
            "是否转人工": to_human,
            "处理建议": advice(text, r, amount),
            "命中词": r["hit"],
        })

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    total = len(rows)
    esc = sum(1 for r in rows if r["是否转人工"] == "是")
    high = sum(1 for r in rows if r["优先级"] == "高")
    print("消息 %d 条 ｜ 转人工 %d (%.0f%%) ｜ 高优先级 %d ｜ 未命中 %d"
          % (total, esc, esc * 100.0 / total, high, len(miss)))
    print("\n意图分布：")
    for name, n in counter.most_common():
        print("  %-10s %3d  (%.0f%%)" % (name, n, n * 100.0 / total))
    print("\n工单类型：")
    for name, n in ticket.most_common():
        print("  %-6s %3d" % (name, n))
    if miss:
        print("\n未命中 %d 条，建议补进 faq.json：" % len(miss))
        for t in miss:
            print("  - " + t)

    # 巡检清单
    P = ["# 店铺巡检清单\n", "> 每天定时跑；查三样：差评与追评、商品状态、竞品动态。\n"]
    P.append("## 一、今日待处理会话\n")
    P.append("| 优先级 | 买家 | 问题 | 工单 | 金额 |")
    P.append("| --- | --- | --- | --- | --- |")
    for r in sorted(rows, key=lambda x: {"高": 0, "中": 1, "低": 2}.get(x["优先级"], 3)):
        if r["是否转人工"] == "否":
            continue
        P.append("| %s | %s | %s | %s | %s |" % (r["优先级"], r["买家ID"], r["消息"][:24], r["工单类型"],
                                                 r["订单金额"] or "-"))
    P.append("")
    P.append("## 二、商品状态（人工核对店铺后台）\n")
    P.append("- [ ] 有没有商品被违规下架")
    P.append("- [ ] 库存是否低于 30 件预警线（见 out/运营日报.md 预警小节）")
    P.append("- [ ] 有没有商品还在投广告但库存已为 0")
    P.append("")
    P.append("## 三、差评与追评\n")
    P.append("- [ ] 导出近 24h 新差评，按「质量 / 物流 / 描述不符 / 客服态度」分类")
    P.append("- [ ] 每条按 50–80 字回复：不反驳、不甩锅、重点写已处理")
    P.append("- [ ] 汇总高频差评 → 反查详情页描述与打包流程（改一处能少几十条）")
    P.append("")
    P.append("## 四、竞品动态\n")
    P.append("- [ ] 竞品是否改价 / 上新 / 做活动（浏览器自动化定时抓）")
    P.append("")
    P.append("## 五、健康指标自检\n")
    P.append("| 指标 | 目标 | 本期 |")
    P.append("| --- | --- | --- |")
    P.append("| 首次响应时长 | ≤ 3 分钟 | 待测 |")
    P.append("| 纠纷介入率 | ≤ 0.5% | 待测 |")
    P.append("| 差评率 | ≤ 1% | 待测 |")
    P.append("| 自动回复覆盖率 | ≥ 80%% | %.0f%%（%d/%d） |"
             % ((total - esc) * 100.0 / total, total - esc, total))
    with open(PATROL, "w", encoding="utf-8") as f:
        f.write("\n".join(P))

    print("\n明细: %s" % OUT)
    print("巡检清单: %s" % PATROL)


if __name__ == "__main__":
    main()
