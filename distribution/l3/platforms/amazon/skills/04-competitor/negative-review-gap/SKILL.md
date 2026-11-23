---
name: negative-review-gap
description: 差评机会点挖掘——1–3 星评论聚类成 6 类失效模式（结构/材质/尺寸/说明/包装/物流），算提及率与可改进度评分（0–10），产出「一句话差异化命题 + 需改的 BOM 项 + 验证方法」。当用户提到「差评能不能改」「用户不满意什么」「差异化怎么做」「改哪个部件」「有没有改款机会」时使用。
layer: 04-competitor
version: 1.0.0
inputs: [target_asins, review_corpus_1_3star, cogs_cny, price_usd, bom_draft]
outputs: [out/<run_id>/差评机会点.md, out/<run_id>/失效模式.csv, cmp_mention_rate, cmp_fix_score, cmp_diff_gap_score, cmp_diff_claim]
upstream: [amz-review-harvest, voc-mining, competitor-deconstruct]
downstream: [market-sizing, visual-strategy, supply-verify, demand-priority]
---

# 差评机会点：把 1 星变成改款清单

## 何时用

1. 要进一个成熟类目，唯一机会是改掉对手改不掉的毛病。
2. 自己产品退货率高，需要定位是哪个失效模式拉起来的。
3. 老板要「差异化」，但团队只会说「做高端一点」——需要 BOM 级动作。
4. 判断某个差评能不能改：物流慢是运营问题，不是产品问题。
5. 给 `market-entry` 的「功能错位」姿势提供判定依据（`cmp_diff_gap_score ≥ 7` 才允许走功能错位）。
6. 给 05 层 `supply-verify` 提供改款需求单（部件级规格与报价要求）。

不归这里：评论量多不多、评论增速看 `competitor-deconstruct`；改完之后怎么拍图讲这个点看 `visual-strategy`；改款后的成本重算看 `profit-model`。本 skill 只解决「改什么、能不能改、值不值」。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `target_asins` | 3–8 个对标 ASIN | 必需，少于 3 个判「样本不足」 |
| `review_corpus_1_3star` | 近 24 个月 1–3 星评论全文 + 星级 + 日期 + 是否 Vine | 单 ASIN ≥ 60 条；跨 ASIN ≥ 200 条；不足时扩到 4 星并在报告标注「含 4 星」 |
| `cogs_cny` | 1688 报价 | 缺失时改动用「增量百分比」表述，不给绝对 USD |
| `price_usd` | 前台实付价 | 必需，成本增量占比分母 |
| `bom_draft` | 现有 BOM 或样品拆解清单 | 缺失时按「部件级」描述（外壳/连接件/底座/包装），不写料号 |
| `qna_corpus` | 商品页 Q&A | 缺失时只用评论，命题需标注「单源验证」 |

## 执行流程

1. **采样**：按 ASIN 抓 1–3 星评论，排序方式选「最近」，取近 24 个月。单 ASIN < 60 条时补 4 星，并在样本表标注星级构成。
2. **清洗**：去掉纯物流抱怨但保留计数（归「物流」桶）、去重（同一买家多子体评论合并）、剔除与产品无关的（错发/差评报复）。

清洗规则（逐条执行，处理结果写进样本表）：

| 规则 | 处理 | 计入分母 |
|---|---|---|
| 同一买家在多个子体留同文 | 合并为 1 条 | 是 |
| 评论内容只有「bad/terrible」无描述 | 保留但不打标签 | 否 |
| 提到 FBA 外包装被压坏 | 归「包装」桶 | 是 |
| 提到「arrived late / wrong address」 | 归「物流」桶，不进 `fix_score` | 仅统计 |
| 提到「not as described」但无具体点 | 保留，需要回读商品页判断是否「说明」桶 | 是 |
| Vine 评论（带 Vine 标） | 保留但单独计数，占比 >30% 时标注可信度降级 | 是 |
| 时间是 24 个月之前 | 剔除（产品可能已迭代） | 否 |

3. **逐条打失效模式标签**（一票一条主标签，最多 1 个副标签）：结构 / 材质 / 尺寸 / 说明 / 包装 / 物流。定义见 `references/failure-modes.md`。
4. **算提及率**：`mention_rate = 该模式评论数 / 有效差评总数`，落 `cmp_mention_rate`。
5. **定候选**：`mention_rate ≥ 15%` 且模式 ∈ {结构, 材质, 尺寸, 说明} → 主命题候选；物流与包装单独处理（见第 8 步）。
6. **查可修复性**：对每个候选，去 1688 搜同类改进件（关键词 = 部件名 + 改进词，如「加厚 底座 防滑」），记录是否有现成件、最小起订量、单价差。
7. **算可改进度评分** `fix_score`（0–10，四项加权，见「判定口径」）。
8. **分流处理**：`fix_score ≥ 7` 进命题；5–7 进备选池；< 5 放弃。物流类不参与评分，改为「运营动作」（换仓/换物流商/改预计送达时间）。
9. **写差异化命题**：一句话 ≤ 40 字，含 1 个可感知数字，指向 1 个失效模式，不写形容词堆叠。
10. **列 BOM 改动项**：每个命题对应 1–3 个具体改动（部件 / 改动内容 / 增量成本 / 供应商），BOM 项必须能报价。
11. **定验证方法**：每个命题给一个可执行的验证（30 条种子评论 / 20 人盲测 / 内部测试次数），带验收标准。
12. **落盘**：`失效模式.csv` + `差评机会点.md`（结论行→失效模式表→评分→命题→BOM→验证）。

算例（真实量级）：5 个 ASIN 共 312 条有效差评。「结构-底座断裂」67 条（`mention_rate = 0.215`）；1688 有加厚底座现成件，单价 +¥2.4（占售价 1.4%）；仅换件 → 供应链 9 分、成本 9 分、结构改动 8 分、合规 10 分 → `fix_score = 0.35×9 + 0.25×9 + 0.25×8 + 0.15×10 = 8.9` → 命题：「加厚 4 mm 底座，承重 30 lb 不断裂」→ BOM：底座 PA66+GF30 加厚至 4 mm、4 颗 M4 自攻钉改预埋铜螺母 → 验证：30 台样机做 200 次侧向推倒测试，0 断裂。

## 判定口径

| 指标 | 阈值 | 判定 |
|---|---|---|
| 有效差评样本 | 单 ASIN < 60 条 | 样本不足，结论只写「观察」 |
| 有效差评样本 | 跨 ASIN ≥ 200 条 | 可出命题 |
| `mention_rate` | ≥ 25% | 核心痛点，主命题必选 |
| `mention_rate` | 15%–25% | 主命题候选 |
| `mention_rate` | 8%–15% | 次要卖点，可写进五点但不做主图 |
| `mention_rate` | < 8% | 忽略（长尾抱怨） |
| 供应链可实现性 | 1688 有现成件 = 10 / 需小改模具 = 6 / 需开新模 = 3 / 无方案 = 0 | 权重 0.35 |
| 成本增量 | ≤3% 售价 = 10 / 3%–6% = 7 / 6%–12% = 4 / >12% = 0 | 权重 0.25 |
| 结构改动 | 仅换料换件 = 10 / 加装配件 = 7 / 改结构 = 4 / 全新设计 = 1 | 权重 0.25 |
| 合规与测试 | 无新增 = 10 / 内测即可 = 7 / 需第三方检测 = 4 / 需认证 = 1 | 权重 0.15 |
| `fix_score` | ≥ 7 | 进差异化命题，`cmp_diff_gap_score` 同值输出 |
| `fix_score` | 5–7 | 备选池，需二次验证 |
| `fix_score` | < 5 | 放弃，不作为卖点 |
| 命题字数 | > 40 字 | 重写；一个命题只解决一个失效模式 |
| 物流类 | 任意提及率 | 不参与 `fix_score`，转运营动作 |
| `improvable_score`（03 层）与本 skill `cmp_fix_score` | 差 > 2 分 | 05 层取较小值填 `differentiation_score`，并在决策卡写明分歧原因 |

## 输出契约

- 落盘：`out/<run_id>/差评机会点.md`、`out/<run_id>/失效模式.csv`。
- CSV 列：字典字段逐字一致 → `sku, category, product, price_usd, cogs_cny, return_rate, differentiation_score`；扩展列 → `cmp_failure_mode, cmp_review_count, cmp_mention_rate, cmp_supply_score, cmp_cost_score, cmp_structure_score, cmp_compliance_score, cmp_fix_score, cmp_diff_claim, cmp_bom_change, cmp_verify_method`。
- 正文五段：**结论行 → 失效模式表（模式/条数/提及率/示例原话）→ 可改进度分解 → 差异化命题 + BOM → 验证与动作**。
- `differentiation_score` 归属规则：本 skill 只输出证据分 `cmp_fix_score`；03 层 `voc-mining` 的 `improvable_score` 与 `demand-priority` 的 `differentiation_score_suggest` 同为候选，最终由 05 层 `decision-control` 取三者较小值填字典字段——防高估，不设二次调整。
- 结论行：`结论：主失效模式 {模式}（提及率 {值}，{条数}/{总数}），可改进度 {分}/10，命题「{一句话}」[B]`

跨层交接字段（本 skill 是 `differentiation_score` 的唯一证据来源）：

| 字段 | 消费层 | 用途 |
|---|---|---|
| `cmp_diff_gap_score` | `market-sizing`、`market-entry`（回写） | ≥7 时 SOM ×1.5；`market-entry` 若已跑过本 skill 则直读，允许「功能错位」 |
| `cmp_diff_claim` | `supply-verify`、`compliance-gate` | 命题直接进五点第 1–2 条与主图副标题；改款规格走 `supply-verify` |
| `cmp_bom_change` | 05-product、06-delivery | 改款成本进三层利润重算，改模具进排产 |
| `cmp_fix_score` → `differentiation_score` | engine/score.py | 0–10 分映射：`differentiation_score = cmp_fix_score`，不得二次调整 |
| `cmp_mention_rate` | `visual-strategy` | 决定副图第 2 张是否放「对比/测试」图 |

## 质检清单

- [ ] 有效差评 ≥200 条（或单 ASIN ≥60），星级构成已标注。
- [ ] 每条评论只打 1 个主标签，副标签单独一列。
- [ ] 物流类没有混进 `fix_score`，已转运营动作。
- [ ] 四项子分都有依据（1688 询价截图/报价、结构判断），不是拍的。
- [ ] 命题 ≤40 字，含至少 1 个数字，只解决 1 个失效模式。
- [ ] 每个 BOM 项都能报价，写明供应商或料号级别描述。
- [ ] 每个命题有验证方法与验收标准（次数/人数/断裂数）。
- [ ] 数据可信度声明：评论为前台抓取标 `[B]`，1688 询价为 `[A]`，无报价的标 `[C]`。

## 反模式

1. **把物流慢做成卖点**。错误：「我们发货更快」。正确：物流类只进运营动作，产品命题必须落在结构/材质/尺寸/说明。
2. **只数关键词不读原话**。错误：搜「broke」得 67 条就下结论。正确：逐条读，区分「底座断裂」与「包装压坏」，两者 BOM 改动完全不同。
3. **命题写成形容词**。错误：「更耐用、更结实」。正确：「加厚 4 mm 底座，承重 30 lb 不断裂」。
4. **`fix_score` 拍分**。正确：四项子分各给证据，成本增量用 `增量成本 / price_usd` 算百分比再查表。
5. **一个命题塞三个改动**。正确：一命题一失效模式，BOM 改动 1–3 项且都服务于同一失效模式。
