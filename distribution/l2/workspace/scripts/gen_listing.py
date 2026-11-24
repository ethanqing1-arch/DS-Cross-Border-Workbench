#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""上架物料生成 + 合规检测 + 多店铺差异化。

流程与视频一致：批量生成 → 机器检测 → 人工复核 → 上线。
脚本负责前三步的一半：生成 + 检测，人工复核由 SKILL 要求人来做。

用法:
    python3 scripts/gen_listing.py
    python3 scripts/gen_listing.py --sku PT-001
"""
import argparse
import csv
import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(BASE, "data", "products.csv")
OUTDIR = os.path.join(BASE, "out", "上架包")
IMPORT = os.path.join(BASE, "out", "平台导入表.csv")
LEDGER = os.path.join(BASE, "out", "上下架台账.csv")
AUDIT = os.path.join(BASE, "out", "合规检测报告.md")
COMMISSION = 0.05

# ---------- 违禁词 ----------
# block：广告法明确禁止，必须改写
BLOCK = {
    "绝对化": ["国家级", "全网第一", "销量第一", "排名第一", "填补国内空白", "100%", "百分百"],
    "虚假功效": ["特效", "神效", "根治", "永不", "当天见效", "三天美白", "立竿见影"],
    "无依据宣传": ["零甲醛", "零添加", "无添加", "绝对安全", "绝对无害"],
    "医疗术语": ["癌症", "糖尿病", "高血压", "处方", "疗程", "医生推荐", "治疗"],
}
# review：可能是合法表述（同品牌自比、可验证事实），需人工判断语境
REVIEW = ["最", "第一", "顶级", "极致", "唯一", "首个", "独家", "首发",
          "纯天然", "野生", "原生态", "古法", "清仓", "最后一天", "特供"]

# 平台标题规则
PLATFORMS = {
    "淘宝": "核心词+属性词+长尾词，关键词密度优先",
    "拼多多": "规格+性价比表达，促销感强",
    "抖音": "场景+话题感，像一句人话",
    "京东": "品质+参数背书，理性表达",
}

# 同一卖点在两个店的差异化表达（避免被判重复铺货）
REWRITE = {
    "磁吸拼接自由组合": ("磁吸模块化，想拼几层拼几层", "带磁吸的拼接设计，层数随桌面改"),
    "桌面5分钟变整齐": ("五分钟收完一桌线", "桌面从乱到齐，只要一杯水的时间"),
    "ABS加厚不塌陷": ("加厚 ABS，压不塌", "用料厚实，装满也不变形"),
    "可裁剪任意尺寸": ("按抽屉尺寸剪，多宽都行", "量好再剪，边角也服帖"),
    "免工具卡扣安装": ("卡扣一按就好，不用工具", "免打孔免工具，装上就能用"),
    "PP材质易清洁": ("PP 料，水一冲就干净", "光面 PP，擦一下就亮"),
    "吸盘防滑不移位": ("吸盘咬住地面，狗扒不动", "底部吸盘锁住，怎么舔都不跑"),
    "减缓进食护肠胃": ("吃慢一点，胃舒服一点", "拉长进食时间，减少呕吐"),
    "可冷冻做冰垫": ("冻一下当冰垫，夏天降温", "塞冰箱冷冻，变成降温垫"),
    "替换头3件套": ("三个替换头，换着玩不腻", "附赠 3 个头，新鲜感管够"),
    "弹性杆不回弹": ("杆有韧性，甩出去能回", "碳纤杆回弹稳，不抽手"),
    "可悬挂收纳": ("带挂绳，收起来不占地", "挂门后就行，随手拿"),
    "铝合金可折叠": ("铝合金，折起来塞包里", "铝材折叠，出差也能带"),
    "6档高度调节": ("六档高度，找到你的颈椎角度", "六个档位，坐着站着都合适"),
    "散热镂空设计": ("镂空背板，机器不闷", "底板开孔，热量往下走"),
}


def load(path):
    if not os.path.exists(path):
        sys.exit("缺少文件: %s" % path)
    with open(path, newline="", encoding="utf-8-sig") as f:
        return [r for r in csv.DictReader(f) if (r.get("SKU") or "").strip()]


def fnum(row, key):
    try:
        return float(row.get(key, 0) or 0)
    except ValueError:
        return 0.0


def scan(text):
    """返回 (block_hits, review_hits)，每条为 (类别/类型, 词)。"""
    block, review = [], []
    for cat, words in BLOCK.items():
        for w in words:
            if w in text:
                block.append((cat, w))
    for w in REVIEW:
        if w in text:
            review.append(("需人工判断", w))
    return block, review


def titles(p):
    name = p["商品名"]
    spec = p.get("规格", "")
    s1, s2, s3 = p.get("卖点1", ""), p.get("卖点2", ""), p.get("卖点3", "")
    who = p.get("目标人群", "")
    cat = p.get("类目", "")
    return {
        "淘宝": "%s %s %s" % (name, spec, s1),
        "拼多多": "%s %s %s 包邮" % (name, spec, s1),
        "抖音": "%s真的能救命 %s %s" % (who or "这个", s1, name),
        "京东": "%s %s %s %s" % (name, spec, s1, s2),
    }


def detail(p, shop="A"):
    name = p["商品名"]
    s = [p.get("卖点%d" % i, "") for i in (1, 2, 3)]
    spec = p.get("规格", "")
    who = p.get("目标人群", "家庭/办公")
    if shop == "A":
        pain = "桌面线越堆越多，找根线要翻半天" if p.get("类目") == "家居" else "%s 用起来总有点不顺" % who
        return [
            "【痛点】%s。" % pain,
            "【卖点】%s；%s；%s。" % tuple(s),
            "【参数】%s。出厂全检，正常使用不易变形。" % spec,
            "【售后】7天无理由 · 破损包赔 · 48小时发货。",
        ]
    # B 店：换叙述顺序与句式
    return [
        "【一句话】%s，%s 用它更顺手。" % (name, who),
        "【为什么】先看三个细节：%s、%s、%s。" % tuple(reversed(s)),
        "【尺码与材质】%s，收到可对照详情图核对。" % spec,
        "【服务】48小时发出 · 7天无理由 · 破损直接补发。",
    ]


def price_calc(p):
    price, cost, ship = fnum(p, "售价"), fnum(p, "进价"), fnum(p, "运费")
    comm = price * COMMISSION
    ad = price * 0.25          # 预估推广费率，正式投放后回填真实值
    ret = price * 0.08         # 预估退货损耗
    contrib = price - cost - comm - ship - ad - ret
    return {
        "售价": "%.2f" % price, "进价": "%.2f" % cost, "运费": "%.2f" % ship,
        "平台佣金": "%.2f" % comm, "预估推广费": "%.2f" % ad, "预估退货损耗": "%.2f" % ret,
        "贡献利润": "%.2f" % contrib,
        "贡献利润率": "%.1f%%" % (contrib / price * 100 if price else 0),
        "保本价": "%.2f" % ((cost + ship) / (1 - COMMISSION)),
    }


def write_sku_md(p):
    os.makedirs(OUTDIR, exist_ok=True)
    t = titles(p)
    b = [p.get("卖点%d" % i, "") for i in (1, 2, 3)]
    b += ["支持7天无理由，破损包赔", "48小时内发出，全国大部分地区次日达"]
    pc = price_calc(p)

    # 合规检测：标题 + 五点 + 详情
    all_text = " ".join(list(t.values()) + b + detail(p, "A") + detail(p, "B"))
    blk, rev = scan(all_text)

    L = []
    L.append("# %s ｜ %s\n" % (p["SKU"], p["商品名"]))
    L.append("规格：%s ｜ 类目：%s ｜ 人群：%s\n" % (p.get("规格", "-"), p.get("类目", "-"), p.get("目标人群", "-")))

    L.append("## 一、分平台标题\n")
    L.append("| 平台 | 规则 | 标题 | 字数 |")
    L.append("| --- | --- | --- | --- |")
    for pf, rule in PLATFORMS.items():
        title = t[pf]
        L.append("| %s | %s | %s | %d |" % (pf, rule, title, len(title)))
    L.append("")

    L.append("## 二、五点描述\n")
    for i, x in enumerate(b, 1):
        L.append("%d. %s" % (i, x))
    L.append("")

    L.append("## 三、详情页（A 店主版 / B 店差异化版）\n")
    L.append("**A 店（痛点开头）**\n")
    for x in detail(p, "A"):
        L.append("- %s" % x)
    L.append("\n**B 店（一句话+细节开头，避免重复铺货判定）**\n")
    for x in detail(p, "B"):
        L.append("- %s" % x)
    L.append("")

    L.append("## 四、合规检测\n")
    if blk:
        L.append("**必须改（明确违规）**\n")
        for cat, w in blk:
            L.append("- `%s`（%s）" % (w, cat))
        L.append("")
    if rev:
        L.append("**需人工判断（可能合法，看语境）**\n")
        for _, w in rev:
            L.append("- `%s` — 检查是否跨品牌/全行业对比、是否误导、是否贬低同行" % w)
        L.append("")
    if not blk and not rev:
        L.append("未命中违禁词词表。仍需人工过一遍价格、库存、功效承诺三类内容。\n")

    L.append("## 五、价格与贡献利润\n")
    L.append("| 项目 | 金额 |")
    L.append("| --- | --- |")
    for k, v in pc.items():
        L.append("| %s | %s |" % (k, v))
    L.append("")

    L.append("## 六、主图脚本（5 张）\n")
    L.append("1. 白底主图：45° 正面 + 角标「%s」" % p.get("卖点1", ""))
    L.append("2. 场景图：%s 使用中，有参照物体现真实尺寸" % p.get("目标人群", "真人使用"))
    L.append("3. 卖点特写：局部放大 + 箭头标注「%s」" % p.get("卖点2", ""))
    L.append("4. 对比图：普通款 vs 本品（不点名竞品）")
    L.append("5. 信任图：服务承诺 + 包装内容物清单")
    L.append("")

    L.append("## 七、资料包清单\n")
    L.append("- [ ] 主图 5 张（800×800）")
    L.append("- [ ] 详情图 6 张（宽 750）")
    L.append("- [ ] 标题（本文件第一节，按平台取用）")
    L.append("- [ ] 五点 + 详情文案（本文件二、三节）")
    L.append("- [ ] 规格属性表（填写平台后台属性项）")
    L.append("- [ ] 合规检测通过记录（本文件第四节）")

    path = os.path.join(OUTDIR, "%s_%s.md" % (p["SKU"], p["商品名"]))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    return path, blk, rev


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sku", default="")
    a = ap.parse_args()

    rows = load(SRC)
    if a.sku:
        rows = [r for r in rows if r["SKU"] == a.sku]
        if not rows:
            sys.exit("没有这个 SKU")

    imp_rows, led_rows, made, audit = [], [], [], []
    for p in rows:
        path, blk, rev = write_sku_md(p)
        made.append(path)
        audit.append((p["SKU"], p["商品名"], blk, rev))
        for pf in PLATFORMS:
            imp_rows.append({
                "平台": pf,
                "SKU": p["SKU"],
                "标题": titles(p)[pf],
                "价格": "%.2f" % fnum(p, "售价"),
                "库存": p.get("库存", "0"),
                "类目": p.get("类目", ""),
                "规格": p.get("规格", ""),
                "主图目录": "images/%s/" % p["SKU"],
                "发货时效": "48h",
            })
        led_rows.append({
            "SKU": p["SKU"], "商品名": p["商品名"], "状态": "待上架",
            "平台": "", "上架时间": "", "下架时间": "", "负责人": "",
            "平台商品ID": "", "备注": "物料已生成，合规检测需人工复核",
        })

    with open(IMPORT, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(imp_rows[0].keys()))
        w.writeheader()
        w.writerows(imp_rows)
    with open(LEDGER, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(led_rows[0].keys()))
        w.writeheader()
        w.writerows(led_rows)

    A = ["# 合规检测报告\n", "> 检测范围：标题（4 平台）+ 五点 + 详情（A/B 两版）。"
         "机器只负责标可疑，最终判断必须人工。\n"]
    total_blk = sum(len(x[2]) for x in audit)
    total_rev = sum(len(x[3]) for x in audit)
    A.append("命中：必须改 %d 处，需人工判断 %d 处。\n" % (total_blk, total_rev))
    A.append("| SKU | 商品名 | 必须改 | 需人工判断 |")
    A.append("| --- | --- | --- | --- |")
    for sku, name, blk, rev in audit:
        A.append("| %s | %s | %d | %d |" % (sku, name, len(blk), len(rev)))
    A.append("")
    for sku, name, blk, rev in audit:
        if not blk and not rev:
            continue
        A.append("## %s %s" % (sku, name))
        for cat, w in blk:
            A.append("- ❌ `%s`（%s）— 必须改写" % (w, cat))
        for _, w in rev:
            A.append("- ⚠️ `%s` — 看语境：同品牌自比或可验证事实可能合法，跨品牌对比则违规" % w)
        A.append("")
    with open(AUDIT, "w", encoding="utf-8") as f:
        f.write("\n".join(A))

    print("生成上架包 %d 份：" % len(made))
    for m in made:
        print("  " + m)
    print("\n合规：必须改 %d 处 ｜ 需人工判断 %d 处 → %s" % (total_blk, total_rev, AUDIT))
    print("平台导入表: %s（每 SKU × 4 平台）" % IMPORT)
    print("上下架台账: %s" % LEDGER)
    print("\n流程：生成 → 检测 → 人工复核（价格/库存/功效承诺）→ 上线 → 回填台账")


if __name__ == "__main__":
    main()
