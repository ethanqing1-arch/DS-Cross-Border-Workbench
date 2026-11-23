---
name: decision-control
description: 决策总控：汇总上游证据跑四维打分（权重 25/25/30/20 写死）、三档结论、SKU 分层与 Go/No-Go 决策卡，并列出证据缺口对结论的降档影响。当用户提到「这个品能不能做」「打分」「四维评分」「上架还是放弃」「Go/No-Go」「决策卡」「SKU 分层」「优先级排序」时使用。
layer: 05-product
version: 1.0.0
inputs: [sku, category, product, monthly_search_volume, competitor_count, top_review_count, top10_share, cogs_cny, price_usd, inbound_usd, referral_rate, fba_fee_usd, ad_share, return_rate, return_loss_ratio, tariff_rate, supply_stability, differentiation_score, ip_risk, cert_required]
outputs: [选品打分.csv, 决策卡.md, 分层清单.md]
upstream: [demand-priority, pricing-ladder, profit-model, supply-verify, compliance-gate]
downstream: [excel-report, deck-report]
---

# 决策总控（四维打分 → 三档结论 → 分层 → 决策卡）

## 何时用

- 一批候选品跑完前四层，需要排出"先做哪个、放弃哪个"。
- 老板要一句结论 + 一张能签字的决策卡。
- 两个品分数接近，需要看证据缺口而不是拍脑袋。
- 已上架的品要复核：该加投、维持还是止损。
- 需要给运营排期：哪些是利润款、哪些只用来引流。

不归这里：算利润细节 → `profit-model`；查侵权与认证 → `compliance-gate`；做 Excel/PPT → `excel-report` / `deck-report`。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `monthly_search_volume` | 卖家精灵 / Sorftime / 前台搜索 | 缺失用类目均值估，标 `[C]`，结论降一档 |
| `competitor_count` | 前台搜索第一页同款数 | 缺失按关键词结果数估，标 `[C]` |
| `top_review_count` | 首页最高评论数 | 缺失取前 3 名均值，标 `[C]` |
| `top10_share` | 前 10 listing 销量占比 | 缺失按评论分布估，标 `[D]`，结论降一档 |
| `cogs_cny` | `supply-verify` 落地成本 | **必需**。缺则结论只能是"补充数据" |
| `price_usd` / `fba_fee_usd` / `inbound_usd` | `profit-model` 输入 | **必需**（利润维度不可缺） |
| `ad_share` / `return_rate` / `return_loss_ratio` / `tariff_rate` / `referral_rate` | `profit-model` 输入 | 按 SPEC 默认值补齐，标 `[C]` |
| `supply_stability` | `supply-verify` 评分 | **必需**。缺则风险维度按 0 分算，标"待验厂" |
| `differentiation_score` | 差异化清单打分，0–10 | 缺失按 5.0 中性值，标 `[D]` |
| `ip_risk` | `compliance-gate` 四查 | **必需**。缺则不得给"上架测试" |
| `cert_required` | `compliance-gate` 判定 | **必需**。缺则不得给"上架测试" |

## 执行流程

1. **收口证据**：把 `profit-model`、`supply-verify`、`compliance-gate` 三份输出的字段拼成一行，字段名逐字用第 3 节数据字典；拼不齐的留空并标 `[缺]`。
2. **算利润四项**：按 SPEC 4.1 算 `毛利 / 毛利率 / 贡献利润 / 贡献利润率`（公式不在本 skill 重写，直接调用 `profit-model` 结果）。
3. **先跑红线**：5 条红线逐条判。触发任一条 → 结论直接"放弃（红线 R#）"，不再进打分，但仍要写决策卡说明触发项。
4. **算四维原始值**：按 4.2 每维先算原始指标（需求 = `log1p(月搜索量)`；竞争 = `log1p(竞品数)×0.5 + log1p(头部评论)×0.25 + top10_share×0.25`；盈利 = `log1p(贡献利润额)×0.5 + 贡献利润率×0.3 + 毛利率×0.2`；风险 = `(1-退货率)×0.3 + 供应稳定性/10×0.3 + 差异化/10×0.25 + (1-ip_risk/10)×0.15`）。
5. **映射到 0–100（绝对锚定，不用 min-max）**：需求 `lin(log10(月搜),3.0,5.7)`；竞争 `100-(0.5×lin(log10竞品,1,4)+0.25×lin(log10头部评论,1.5,5)+0.25×top10_share×100)`；盈利 `0.5×lin(log1p(贡献利润),0,log1p(12))+0.3×min(100,贡献率/0.35×100)+0.2×min(100,毛利率/0.80×100)`；风险 `30×(1-退货率)+30×(供应稳定性/10)+25×(差异化/10)+15×(1-ip_risk/10)`。`lin(v,a,b)=clamp((v-a)/(b-a)×100,0,100)`。锚点表见 `references/scoring-and-card.md` 第 2 节。选绝对锚定的原因：min-max 会让每批候选必然出现一个 100 分，跨批次与历史分数无法比较。
6. **加权求和**：`总分 = 需求×0.25 + 竞争×0.25 + 盈利×0.30 + 风险×0.20`。权重写死，任何理由都不改。
7. **分档**：`≥ 60` 上架测试 / `48–59` 观察 / `< 48` 放弃。分档后被证据缺口或抗压不足降档的，写"原始 62 → 降档 观察（原因：top10_share 为 D 级）"。
8. **SKU 分层**：按第 4 节规则分利润款 / 引流款 / 常规款 / 观察款 / 清仓款，一层只能落一个。
9. **排优先级**：同档内按 `贡献利润 × 需求分` 降序排，取前 3 进本月排期。
10. **写决策卡**：投入上限、验证指标（30/60/90 天）、止损线、复盘日期，四件都要有数字。
11. **写证据缺口**：逐条列"缺哪个字段 → 影响哪个维度 → 结论降几档 → 补数据的最快路径"。
12. **落盘**：三个文件写 `out/<run_id>/`，并把 `选品打分.csv` 交给 `excel-report` 生成看板。

取数口径：所有前台抓取记采集时间戳；同批候选品用同一个采集日、同一个 FX、同一个 `referral_rate` 基准，否则分数不可比。

## 判定口径

四维权重（写死，不得改）：

| 维度 | 权重 |
|---|---|
| 需求强度 | 25% |
| 竞争压力 | 25% |
| 盈利 | 30% |
| 风险 | 20% |

三档结论：

| 总分 | 结论 | 动作 |
|---|---|---|
| ≥ 60 | 上架测试 | 进首单排期，30 天验证 |
| 48–59 | 观察 | 首单减半，只投精准词，60 天复核 |
| < 48 | 放弃 | 不备货、不开模 |

红线优先于分数：任一条触发，无论总分多少都不得进入"上架测试"（毛利率 < 30% / 贡献利润率 < 8% / 贡献利润 < 3 USD / `ip_risk ≥ 7` 或无资质且 `cert_required = 1` / `supply_stability < 4`）。

垄断度分档（只做定性说明，不改分数）：

| `top10_share` | 判定 | 含义 |
|---|---|---|
| < 0.45 | 分散 | 有冷启动窗口 |
| 0.45–0.65 | 集中 | 需差异化或价格带错位 |
| > 0.65 | 寡头 | 无供应链优势不进 |

SKU 分层：

| 层 | 规则（同时满足） | 运营口径 |
|---|---|---|
| 利润款 | 总分 ≥ 60 且 贡献利润率 ≥ 20% | 主推，广告预算优先，可承担高 `ad_share` |
| 引流款 | 总分 ≥ 60 且 贡献利润率 8%–20% 且 需求分 ≥ 70 | 拉流量与评论，`ad_share` ≤ 0.25，不追利润 |
| 常规款 | 总分 ≥ 60 且 不满足以上两条 | 按计划上架，稳价 |
| 观察款 | 48 ≤ 总分 ≤ 59 | 小批量，只测精准词 |
| 清仓款 | 总分 < 48，或有库存且退货率 ≥ 20%，或库存 > 60 天销量 | 降价清库，不再补货 |

## 输出契约

- 落盘：`out/<run_id>/选品打分.csv`、`out/<run_id>/决策卡.md`、`out/<run_id>/分层清单.md`
- `选品打分.csv` 列（与 `engine/score.py` 逐字对齐）：`sku, category, product, cogs_cny, price_usd, inbound_usd, referral_rate, fba_fee_usd, ad_share, return_rate, return_loss_ratio, tariff_rate, monthly_search_volume, competitor_count, top_review_count, top10_share, supply_stability, differentiation_score, ip_risk, cert_required, gross_margin, contribution_profit_usd, contribution_margin, score_demand, score_competition, score_profit, score_risk, score_total, verdict, redline_flags, evidence_grade`
- 扩展列：`sku_tier, rank, downgraded_reason, gap_fields`
- `verdict` 只允许：`上架测试` / `观察` / `放弃`。
- 正文格式：结论行（`结论：N 可做 / N 观察 / N 放弃（共 M 个候选）`）→ 打分表 → 分层清单 → 证据缺口 → 决策卡。结论后标 `[A]`/`[B]`/`[C]`/`[D]`。

## 质检清单

- [ ] 权重仍是 25/25/30/20，没有为了某个品调权。
- [ ] 五条红线在打分之前先跑了一遍，触发项已写进 `redline_flags`。
- [ ] 四维原始值都留了中间结果，能手工复算到总分。
- [ ] `differentiation_score` 取三个候选分的**最小值**（`differentiation_score_suggest` / `cmp_fix_score` / 本层判断），防高估。
- [ ] 四维用绝对锚点映射，没有改回 min-max；同一 SKU 两次跑分误差 ≤ 0.5。
- [ ] 分层每品只落一层，规则与第 4 节一致。
- [ ] 决策卡四个要素（投入上限/验证指标/止损线/复盘日期）都有数字与日期。
- [ ] 证据缺口小节列出了"缺什么 → 降几档 → 怎么补"。
- [ ] 数据可信度声明：D 级字段占比 ___%；> 30% 时结论只能是"观察"或"补充数据"。

## 反模式

- 分数 58，手动加 3 分凑"上架测试"。→ 错：分档是硬阈值，宁可观察；凑分会把库存风险放大。
- 红线触发了还继续打分排第一。→ 错：红线优先于分数，触发即放弃，打分只作记录。
- 权重按品类微调（"这个类目竞争更重要"）。→ 错：权重写死 25/25/30/20，要表达竞争重要就改 `differentiation_score`，不改权。
- 决策卡写"投入控制在合理范围"。→ 错：要写数字（首单 500 件 = 2.1 万 CNY + 头程 4,800 USD 上限），否则不能签字。
- 证据缺口写"数据待完善"。→ 错：要写缺哪一行字段、影响哪一维、降几档、今天谁去补。
