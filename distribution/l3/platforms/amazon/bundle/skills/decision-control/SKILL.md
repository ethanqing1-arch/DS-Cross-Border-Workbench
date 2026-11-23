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
| `monthly_search_volume` | 同站同词 Amazon 站内量级导出 | 缺则标无源。站外量、下拉和排名单列。 |
| `competitor_count` | 同一可比总体的在售同款数 | 缺则标无源，首屏计数另存。 |
| `top_review_count` | 同一可比总体的最高评论数 | 缺则标无源。 |
| `top10_share` | 同一可比总体的前 10 listing 销量占比 | 缺则标无源，评论代理另存。 |
| `cogs_cny` | `supply-verify` 同装量含税采购价，物流分列 | **必需**。缺则结论只能是"补充数据" |
| `price_usd` / `fba_fee_usd` / `inbound_usd` | `profit-model` 输入 | **必需**（利润维度不可缺） |
| `ad_share` / `return_rate` / `return_loss_ratio` / `tariff_rate` / `referral_rate` | `profit-model` 输入 | 缺证则标无源，默认值只用于审计情景。 |
| `supply_stability` | `supply-verify` 评分 | **必需**。缺则标「无源」，待验厂 |
| `differentiation_score` | 差异化清单打分，0–10 | 缺则标「无源」，待核差异化清单 |
| `ip_risk` | `compliance-gate` 四查 | **必需**。缺则不得给"上架测试" |
| `cert_required` | `compliance-gate` 判定 | **必需**。缺则不得给"上架测试" |

## 执行流程

1. **收口证据**：一 SKU 一行，用工作区 `95-engine/SKILL_SPEC.md` §4.4 的 `field_evidence` 传入字段值、来源、证据等级、日期、站点与口径，竞争三项附共同 `cohort`。缺失时标「无源」/D。
2. **运行引擎**：用工作区 `python3 95-engine/score.py --input <候选表> --out <输出目录>`。利润、八个敏感性情景、红线和四维分由该入口计算。复核分数使用该运行的输入与口径。
3. **执行门禁**：正式分档 ≥60 上架测试、48 至不足 60 观察、<48 放弃。已证实 R2–R5 放弃，R1 或抗压破线封顶观察。无源、FBA 区间冲突或 D 级字段不得进入正式权重，证据不足时留空正式分与红线，结论为观察并补证。D >30% 封顶观察一次。
4. **落实决策**：同档按正式分排序，决策卡优先取可上架测试品；观察及放弃卡的测试投入为零。报告逐条列字段缺口、导致的门禁、补数负责人及来源。历史复算只读 `audit_score_total`。

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
| 48 至不足 60 或被门禁封顶 | 观察 | 测试投入为零，复核后重跑 |
| < 48 | 放弃 | 不备货、不开模 |

红线优先于分数：任一条触发，无论总分多少都不得进入"上架测试"（毛利率 < 30% / 贡献利润率 < 8% / 贡献利润 < 3 USD 的站点本币等值 / `ip_risk ≥ 7` 或无资质且 `cert_required = 1` / `supply_stability < 4`）。

垄断度分档（只做定性说明，不改分数）：

| `top10_share` | 判定 | 含义 |
|---|---|---|
| < 0.45 | 分散 | 有冷启动窗口 |
| 0.45–0.65 | 集中 | 需差异化或价格带错位 |
| > 0.65 | 寡头 | 无供应链优势不进 |

SKU 分层：

| 层 | 规则（同时满足） | 运营口径 |
|---|---|---|
| 利润款 | 结论为上架测试 且 贡献利润率 ≥ 20% | 主推，广告预算优先，可承担高 `ad_share` |
| 引流款 | 结论为上架测试 且 贡献利润率 8%–20% 且 需求分 ≥ 70 | 拉流量与评论，`ad_share` ≤ 0.25，不追利润 |
| 常规款 | 结论为上架测试 且 不满足以上两条 | 按计划上架，稳价 |
| 观察款 | 结论为观察 | 补证或复核后重跑 |
| 不做/清仓 | 结论为放弃 | 不下测试单，已有库存按经营流程处理 |

## 输出契约

- 落盘：`out/<run_id>/选品打分.csv`、`out/<run_id>/决策卡.md`、`out/<run_id>/分层清单.md`
- `选品打分.csv` 列按工作区 `95-engine/SKILL_SPEC.md` §4.6。重点检查 `field_evidence`、`evidence_flags` 和 `decision_gates`。
- 门禁原因读 `evidence_flags` 和 `decision_gates`。
- `verdict` 只允许：`上架测试` / `观察` / `放弃`。
- 正文格式：结论行（`结论：N 可做 / N 观察 / N 放弃（共 M 个候选）`）→ 打分表 → 分层清单 → 证据缺口 → 决策卡。结论后标 `[A]`/`[B]`/`[C]`/`[D]`。

## 质检清单

- [ ] 权重仍是 25/25/30/20，没有为了某个品调权。
- [ ] 已核红线写入 `redline_flags`。缺证行写「未判定」，测试投入为零。
- [ ] 四维原始值都留了中间结果，能手工复算到总分。
- [ ] `differentiation_score` 取三个候选分的**最小值**（`differentiation_score_suggest` / `cmp_fix_score` / 本层判断），防高估。
- [ ] 四维用绝对锚点映射，没有改回 min-max；同一 SKU 两次跑分误差 ≤ 0.5。
- [ ] 分层每品只落一层，规则与第 4 节一致。
- [ ] GO 决策卡给投入上限、验证指标、止损线和复盘日期。观察及放弃卡的测试投入为零。
- [ ] 证据缺口小节列出了"缺什么 → 降几档 → 怎么补"。
- [ ] `field_evidence` 逐项齐全；D 级占比以 18 个决策字段为分母，超过 30% 已封顶观察。

## 反模式

- 分数 58，手动加 3 分凑"上架测试"。→ 错：分档是硬阈值，宁可观察；凑分会把库存风险放大。
- 红线触发了还继续打分排第一。→ 错：红线优先于分数，触发即放弃，打分只作记录。
- 权重按品类微调（"这个类目竞争更重要"）。→ 错：权重写死 25/25/30/20，要表达竞争重要就改 `differentiation_score`，不改权。
- 决策卡写"投入控制在合理范围"。→ 错：要写数字（首单 500 件 = 2.1 万 CNY + 头程 4,800 USD 上限），否则不能签字。
- 证据缺口写"数据待完善"。→ 错：要写缺哪一行字段、影响哪一维、降几档、今天谁去补。
