# 6 个 sheet 的列定义（`excel-report`）

统一规则：第 1 行（总览为第 1–2 行）是表头；统一字典字段名逐字不改；数字列不写单位进列名，单位写在第 1 行标题的批注或列头括号里。

## 1. 总览

| 列 | 列名 | 类型/格式 | 说明 |
|---|---|---|---|
| A | `rank` | 整数 | 优先级，按 `贡献利润 × 需求分` 降序 |
| B | `sku` | 文本 | 内部编号 |
| C | `product` | 文本 | 商品名 |
| D | `category` | 文本 | 品类 |
| E | `price_usd` | `#,##0.00` | 售价 |
| F | `cogs_cny` | `#,##0.00` | 落地采购价 |
| G | `contribution_profit_usd` | `#,##0.00` | 贡献利润 |
| H | `contribution_margin` | `0.0%` | 贡献利润率（0–1 小数） |
| I | `gross_margin` | `0.0%` | 毛利率 |
| J | `score_total` | `0.0` | 总分 |
| K | `verdict` | 文本 | 上架测试 / 小批量观察 / 放弃 |
| L | `redline_flags` | 文本 | PASS 或 R2\|R3 |
| M | `sku_tier` | 文本 | 利润款 / 引流款 / 常规款 / 观察款 / 清仓款 |
| N | `evidence_grade` | 文本 | A/B/C/D |

首行标题：`A1` 写 `<run_id> 选品总览`；`A2` 写 `数据可信度：A×n / B×n / C×n / D×n，D 级占比 x%`。表头在第 3 行，数据从第 4 行起，冻结 `A4`，筛选 `A3:N{last}`。

## 2. 打分明细

| 列 | 列名 | 格式 | 说明 |
|---|---|---|---|
| A | `sku` | 文本 | |
| B | `product` | 文本 | |
| C | `score_demand` | `0.0` | 需求强度分 |
| D | `score_competition` | `0.0` | 竞争压力分（已取反） |
| E | `score_profit` | `0.0` | 盈利分 |
| F | `score_risk` | `0.0` | 风险分 |
| G | `weight_demand` | `0%` | 0.25（常量列，便于审计权重） |
| H | `weight_competition` | `0%` | 0.25 |
| I | `weight_profit` | `0%` | 0.30 |
| J | `weight_risk` | `0%` | 0.20 |
| K | `score_total` | `0.0` | 加权和，公式列：`=C4*G4+D4*H4+E4*I4+F4*J4` |
| L | `top10_share` | `0.00` | 垄断度 |
| M | `downgraded_reason` | 文本 | 降档原因，无则空 |

权重列写成常量列而不是硬编码在公式里，是为了让审计者一眼看到 25/25/30/20 没被改。

## 3. 利润瀑布

每品一个 10 行区块，区块间隔 1 行空行。

| 列 | 列名 | 格式 | 说明 |
|---|---|---|---|
| A | `item` | 文本 | 行项目名（见下） |
| B | `amount_usd` | `#,##0.00` | 金额（扣减项为负数） |
| C | `pct_of_price` | `0.0%` | 占售价比 |
| D | `formula` | 文本 | 该行算式文本，便于复核 |
| E | `note` | 文本 | 口径备注 |

固定 10 行项目与算式：

| # | `item` | `formula` |
|---|---|---|
| 1 | 售价 | `price_usd` |
| 2 | 采购 | `- cogs_cny / FX` |
| 3 | 头程 | `- inbound_usd` |
| 4 | 关税 | `- cogs_usd × tariff_rate` |
| 5 | 毛利 | 1−2−3−4 |
| 6 | 平台佣金 | `- price × referral_rate` |
| 7 | FBA | `- fba_fee_usd` |
| 8 | 推广 | `- price × ad_share` |
| 9 | 退货损耗 | `- price × return_rate × return_loss_ratio` |
| 10 | 贡献利润 | 5−6−7−8−9 |

## 4. 关键词

| 列 | 列名 | 格式 | 说明 |
|---|---|---|---|
| A | `keyword` | 文本 | 关键词原文 |
| B | `search_volume` | `#,##0` | 月搜索量 |
| C | `competition_level` | 文本 | 低 / 中 / 高 |
| D | `cpc_usd` | `#,##0.00` | 建议竞价 |
| E | `relevance` | `0.0` | 与本品的相关度 0–10 |
| F | `used_in_title` | 文本 | 是 / 否 |

排序：`search_volume` 降序；只保留 `relevance ≥ 5` 的词。

## 5. 评论痛点

| 列 | 列名 | 格式 | 说明 |
|---|---|---|---|
| A | `pain_point` | 文本 | 痛点一句话 |
| B | `mention_count` | `#,##0` | 提及次数 |
| C | `share` | `0.0%` | 占样本评论比例 |
| D | `severity` | 文本 | 低 / 中 / 高 |
| E | `action` | 文本 | 对应产品动作 |

排序：`mention_count` 降序；门槛 `mention_count ≥ 3`，样本量写进标题行（`样本 N 条评论`）。

## 6. 竞品对标

| 列 | 列名 | 格式 | 说明 |
|---|---|---|---|
| A | `asin` | 文本 | 竞品 ASIN |
| B | `brand` | 文本 | 品牌 |
| C | `price_usd` | `#,##0.00` | 售价 |
| D | `review_count` | `#,##0` | 评论数 |
| E | `rating` | `0.0` | 星级 |
| F | `bsr` | `#,##0` | 类目排名 |
| G | `est_monthly_sales` | `#,##0` | 估算月销 |
| H | `top10_share` | `0.00` | 垄断度 |
| I | `image_style` | 文本 | 主图风格（白底/场景/拼图） |
| J | `note` | 文本 | 差异点或威胁点 |

排序：`est_monthly_sales` 降序；前 10 行加浅色底纹表示"核心竞品"。

## 7. 回读校验脚本（照抄可用）

```python
from openpyxl import load_workbook

EXPECTED = ["总览", "打分明细", "利润瀑布", "关键词", "评论痛点", "竞品对标"]

def verify(path, rows_by_sheet, header_rows):
    wb = load_workbook(path, read_only=True)
    assert wb.sheetnames == EXPECTED, f"sheet 顺序错: {wb.sheetnames}"
    for name in EXPECTED:
        ws = wb[name]
        expect = rows_by_sheet[name] + header_rows[name]
        assert ws.max_row == expect, f"{name} 行数 {ws.max_row} != {expect}"
    wb.close()
```

`header_rows`：总览 3（标题 1 + 可信度 1 + 表头 1），其余为 1。
`rows_by_sheet`：源数据行数；sheet 内按品分区块的（利润瀑布），行数 = `品数 × 10 + 品数`（含空行）。
