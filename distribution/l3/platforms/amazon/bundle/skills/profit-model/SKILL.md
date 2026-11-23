---
name: profit-model
description: 三层利润测算：按硬口径算单件利润瀑布、三条盈亏平衡点与四组敏感性，并逐条打勾五条红线。当用户提到「利润测算」「这个品赚钱吗」「算成本」「盈亏平衡」「最低卖多少钱」「最高采购价」「ad_share 能压到多少」或需要判定某 SKU 是否触红线时使用。
layer: 05-product
version: 1.1.0
inputs: [sku, product, category, cogs_cny, price_usd, inbound_usd, referral_rate, fba_fee_usd, ad_share, return_rate, return_loss_ratio, tariff_rate, FX]
outputs: [利润瀑布.csv, 利润瀑布.md, 红线判定.md]
upstream: [pricing-ladder, supply-verify]
downstream: [decision-control, excel-report, deck-report]
---

# 三层利润测算（单件利润瀑布 + 盈亏平衡 + 敏感性）

## 何时用

- 拿到一个候选品，需要先回答"这件到底赚几块钱"，再谈别的维度。
- 供应商报价变了（涨 5 毛、涨 2 块），要判断还能不能做。
- 定价谈判：老板问"最低卖多少不亏""采购价压到多少才达标"。
- 新品期准备给广告预算，需要知道 `ad_share` 的天花板在哪。
- 结论冲突时复核：别的 skill 说"可做"，但利润侧可能是负的。

不归这里：算不出采购价（还没询价）→ 先去 `supply-verify` 拿 `cogs_cny`；要做全维打分与 Go/No-Go → 去 `decision-control`。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `sku` | 人工编号或 `category` 加序号 | 用 `category` 加当日流水号补齐，不阻塞计算 |
| `cogs_cny` | 1688 含税报价（含包装） | **必需**。缺则先跑 `supply-verify`；本 skill 只出"待补采购价"骨架，不给结论 |
| `price_usd` | 竞品价格带取中位 + 自身定位 | 缺失时取同款 Top10 售价中位数，标 `[C]` |
| `inbound_usd` | 货代报价 ÷ 件数（头程 + 入仓） | 缺失时按重量估：空运 5.5 USD/kg、海运 1.2 USD/kg，标 `[C]` |
| `referral_rate` | 类目佣金，默认 0.15 | 缺失取 0.15，标 `[B]`（以后台费率为准） |
| `fba_fee_usd` | 按尺寸分段查 `references/fba-fees.md` | **必需**。缺尺寸就先用最长边 + 重量套分段，标 `[C]` |
| `ad_share` | 目标值：新品期 0.25–0.45 | 缺失取 0.30，标 `[C]` |
| `return_rate` | 类目退货率（后台或行业均值） | 缺失取 0.08，标 `[C]`；服装类取 0.15 |
| `return_loss_ratio` | 可二次销售 0.15；不可 1.0 | 缺失按"不可二次销售"取 1.0（保守），标 `[D]` |
| `tariff_rate` | 关税 + 附加，默认 0.25 视品类 | 缺失取 0.25，标 `[C]` |
| `FX` | 默认 7.15，可配 | 缺失取 7.15 |

## 执行流程

1. **换算采购成本**：`cogs_usd = cogs_cny / FX`。中间量保留 4 位小数，只在展示层取 2 位；不许先取整到分再连减。
2. **算关税**：`tariff = cogs_usd × tariff_rate`。关税基数=申报货值（= `cogs_usd`），**禁止按售价算**。
3. **算毛利**：`毛利 = price - cogs_usd - inbound - tariff`；`毛利率 = 毛利 / price`。
4. **算平台与履约**：`平台与履约 = price × referral_rate + fba_fee`。
5. **算推广**：`推广 = price × ad_share`。
6. **算退货损耗**：`退货损耗 = price × return_rate × return_loss_ratio`。
7. **算贡献利润**：`贡献利润 = price - cogs_usd - inbound - tariff - 平台与履约 - 推广 - 退货损耗`；`贡献利润率 = 贡献利润 / price`。
8. **填瀑布表**：`售价 → 采购 → 头程 → 关税 → 平台佣金 → FBA → 推广 → 退货损耗 → 贡献利润`，逐行扣减，每行给金额与占售价比；中间插一行"毛利"小计。
9. **算三条盈亏平衡点**：`P* = (cogs_usd×(1+tariff_rate) + inbound + fba_fee) / (1 - referral_rate - ad_share - return_rate×return_loss_ratio)`，再按 `references/formula.md` 第 3 节解最低售价、最高采购价、可承受最大 `ad_share`。三项都必须出数，不许只给一条。
10. **跑四组敏感性**：采购价 ±15%、售价 ±10%、退货率 ±5pt、`ad_share` ±10pt，共 8 个情景，各算贡献利润与变化率，输出表格，见第 4 组口径。
11. **逐条打勾红线**：5 条每条给"通过 / 触发 + 触发值 + 差多少"，写进 `红线判定.md`。
12. **落盘**：三个文件写 `out/<run_id>/`，`run_id = YYYYMMDD-HHMM-<category-slug>`。

取数口径：`price_usd` 取同款 Top10 售价中位数并记录采集时间；`return_rate` 取后台近 90 天真实退货率，没有就取类目均值并标 `[C]`；`FX` 用当日中国银行现汇卖出价，全批候选品用同一个值。多 SKU 批量跑时，`referral_rate`、`tariff_rate`、`ad_share` 基准、`return_loss_ratio` 四项也全批统一；只在敏感性块里变，不在主表里按品改，否则贡献利润率不可比。

## 判定口径

红线（任何一条触发，无论分数多高都不得进入"上架测试"）：

| # | 红线 | 阈值 | 触发后结论 |
|---|---|---|---|
| 1 | 毛利率 | < 30% | 不得上架测试 |
| 2 | 贡献利润率 | < 8% | 不得上架测试 |
| 3 | 贡献利润 | < 3 USD/件 | 不得上架测试（低价品绝对额不够覆盖一次广告点击） |
| 4 | 侵权/资质 | `ip_risk ≥ 7`，或 `cert_required = 1` 且卖家无资质 | 不得上架测试 |
| 5 | 供应稳定性 | `supply_stability < 4` | 不得上架测试（断货风险不可控） |

利润健康度补充分档（只用于排期与文案，不改变红线）：

| 贡献利润率 | 判定 | 动作 |
|---|---|---|
| ≥ 20% | 利润款候选 | 优先排期，可承担更高 `ad_share` |
| 12%–20% | 常规款 | 按计划上架，`ad_share` ≤ 0.30 |
| 8%–12% | 薄利款 | 只在垄断度 < 0.45 且供应稳定 ≥ 6 时上架 |
| < 8% | 触发红线 2 | 先谈采购价，或减包装降 FBA 分段 |

敏感性判定（8 情景逐行判）：

| 情景结果 | 标记 | 对结论的影响 |
|---|---|---|
| 全部情景贡献利润率 ≥ 8% 且 ≥ 3 USD | 抗压充足 | 不降档 |
| 1–2 个情景破线 | 抗压一般 | 结论最高"观察"，破线项写进止损线 |
| ≥ 3 个情景破线，或 `ad_share +10pt` 破线 | 抗压不足 | 结论最高"观察"，先修结构再谈上架 |

利润字段的证据等级取值（`evidence_grade` 取五项里最低的一级）：

| 字段 | A | B | C | D |
|---|---|---|---|---|
| `cogs_cny` | 1688 开票价 + 专票 | 图搜同款报价 | 同类均值 | 经验估 |
| `fba_fee_usd` | 后台费用预览 | 官方费率卡 | 按分段套表 | — |
| `ad_share` | 广告报表 | 竞品投放反推 | 工具估算 | 0.30 默认 |
| `return_rate` | 后台近 90 天 | — | 类目均值 | 0.08 默认 |
| `tariff_rate` | 报关单 | 货代书面确认 | 0.25 默认 | — |

出现任一 D 级字段 → 按 4.4 把结论封顶为"观察"，不参与"上架测试"排期。

## 输出契约

- 落盘：`out/<run_id>/利润瀑布.csv`、`out/<run_id>/利润瀑布.md`、`out/<run_id>/红线判定.md`
- CSV 列（与 `engine/score.py` 的 schema 对齐，字段名逐字一致）：`sku, category, product, cogs_cny, price_usd, inbound_usd, referral_rate, fba_fee_usd, ad_share, return_rate, return_loss_ratio, tariff_rate, gross_profit_usd, gross_margin, contribution_profit_usd, contribution_margin, breakeven_price_usd, max_cogs_cny, max_ad_share, redline_flags, evidence_grade`
- `redline_flags` 写触发项编号，竖线分隔，如 `R2|R3`；全通过写 `PASS`。
- 本 skill 扩展列（不在统一字典内，允许追加）：`tariff_usd, referral_usd, ad_usd, return_loss_usd, sensitivity_broken_count`
- 正文格式：先结论（一句：贡献利润 X USD、率 Y%、红线几条）→ 瀑布表 → 三条平衡点 → 8 情景敏感性表 → 今天要做的动作。结论后标 `[A]`/`[B]`/`[C]`/`[D]`。

## 质检清单

- [ ] `cogs_usd` 用 `cogs_cny / FX` 算，FX 全批一致，未混用美元采购价。
- [ ] `tariff` 用 `cogs_usd × tariff_rate`，没有出现按 `price` 计征的算法。
- [ ] 六项扣减全部出现，没漏 `tariff`、没漏 `退货损耗`。
- [ ] 三条盈亏平衡点都有数字，不是"再算一下"。
- [ ] 8 个敏感性情景全跑，出的是表格不是一段话。
- [ ] 5 条红线逐条打勾，触发项写了触发值与差值（还差多少到阈值）。
- [ ] `redline_flags` 与红线判定表一致，无手工改数。
- [ ] 五项成本字段各自的证据等级已记，整行 `evidence_grade` 取最低一级。
- [ ] 数据可信度声明：本结论 D 级字段占比 = ___%；> 30% 时结论只能写"观察 / 补充数据"。

## 反模式

- 只报"毛利率 45%，可以做"。→ 错：漏了 `ad_share` 与退货损耗，毛利率高不代表贡献利润为正；必须给贡献利润绝对额与率。
- 用 `cogs_cny` 直接减 `price_usd`。→ 错：必须先除 FX；汇率错一次整张表全错，会误判红线 1。
- 关税按 `price × tariff_rate` 算。→ 错：基数只能是申报货值 `cogs_usd`；按售价算会把关税放大 3–6 倍，好品被错杀。
- `ad_share` 取 0.30 写死不再动。→ 错：必须反解"可承受最大 `ad_share`"，否则不知道广告预算天花板。
- 红线判定写"利润偏低，建议优化"。→ 错：必须写触发哪条、触发值、差多少；无动作是空话。
- 把 `ad_share` 与 `return_rate` 用同一批候选品的平均值套到每个品。→ 错：这两个是品级参数；套平均会让高低价品互相污染，红线判定失真。
