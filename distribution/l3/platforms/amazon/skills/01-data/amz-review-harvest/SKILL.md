---
name: amz-review-harvest
description: 抓取 Amazon 美国站评论并清洗（星级/时间/VP/变体/有用票），做去重、去水军与抽样，输出近 12 个月 ≥300 条可信评论集。当用户提到「抓评论」「评论分析」「差评」「好评率」「水军」「刷单评论」「评论抽样」「VP 评论」或需要给 VOC 挖痛点准备语料时使用。
layer: 01-data
version: 1.0.0
inputs: [asin_list, listing_snapshot.csv, review_window_months, min_reviews_per_asin, category]
outputs: [reviews.csv, sample_manifest.md, review_quality.md]
upstream: [amz-listing-scrape]
downstream: [voc-mining, demand-priority, negative-review-gap]
---

# Amazon 评论抓取与清洗

## 何时用

- 要做 VOC 挖痛点，需要一份干净的评论语料：星级、时间、VP、变体、有用票齐全。
- 判某个竞品的 4.3 分是真口碑还是刷出来的：要看水军占比与时间分布。
- 新品只有 40 条评论，要判断「评论少」是产品问题还是上架太新。
- 差评集中在某个变体（如某个颜色掉漆），要按变体拆开看。
- 不归这里：把评论聚成痛点 → `03-demand/voc-mining`；判断需求优先级 → `03-demand/demand-priority`；算退货率 → `05-product/profit-model`；爬 Q&A → 本 skill 只取评论，Q&A 由 `voc-mining` 的输入契约单独接。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `asin_list` | 上游 `listing_snapshot.csv` 的 `scrape_status=ok` 行 | 缺失：先跑 `amz-listing-scrape`，不在此 skill 里临时选 ASIN。 |
| `listing_snapshot.csv` | `amz-listing-scrape` 产出 | 缺失：`variation_count`、`top_review_count` 只能现场补抓，标 B。 |
| `review_window_months` | 默认 12 | 必须显式写进报告；改成 24 时整份语料标 C。 |
| `min_reviews_per_asin` | 默认 300（近 12 个月） | 不足 300 的 ASIN 按「步骤 5 降级」处理，不得静默放过。 |
| `category` | 输入 | 必需：用于水军句式的类目词典（如 `kitchen` 的「game changer」模板句）。 |
| `max_pages_per_asin` | 默认 40 页（约 400 条） | 翻到时间下界即停，不追全量。 |

## 执行流程

1. **定目标集**：取 `listing_snapshot.csv` 中 `scrape_status=ok` 且 `rating_count` ≥50 的 ASIN，按 `rating_count` 降序取前 20；加卖家指定对标 ASIN，总 ≤23。
2. **定排序方式**：评论列表切到 `Most recent`（不默认 `Top reviews`，后者是算法加权，时间分布失真）。记录排序方式到 manifest。
3. **逐 ASIN 翻页**：从第 1 页开始，每页 10 条，翻到评论日期早于「今天 − 12 个月」即停；单 ASIN 上限 40 页 / 400 条；全批上限 5000 条。
4. **逐条抽字段**：`review_id`（页面 review 元素唯一标识）、`asin`、`rating`（1–5）、`review_date`（`Reviewed in the United States on March 5, 2025` → `2025-03-05`）、`verified_purchase`（有 `Verified Purchase` 为 1）、`variant`（`Color: Black` / `Size: Large` 原文）、`helpful_votes`（`12 people found this helpful` → 12，无则 0）、`review_title`、`review_text`（全文，不截断）、`has_image`（0/1）。
5. **抽样充足性判定**：按 ASIN 统计近 12 个月条数。
   - ≥300 条 → 全量入样，`sample_status=full`，标 B。
   - 100–299 条 → 全量入样，`sample_status=thin`，标 C，报告注明「样本不足 300，情感结论仅供参考」。
   - <100 条 → 扩窗到 24 个月补足；补后仍 <100 → `sample_status=insufficient`，该 ASIN 不进 Top 榜，只做定性引用，标 D。
6. **去重**：同一 ASIN 内做文本相似判定（3-gram shingle，Jaccard ≥0.85）→ 视为重复组；每组保留「日期最早 + `helpful_votes` 最高」各 1 条（同一条则 1 条），其余标 `dup_group=<组号>` 并从分析集剔除。
   - 跨 ASIN 完全同文（相似度 =1.0）→ 全部标 `cross_asin_dup=1`，单独出表，不进分析集。
7. **去水军**（三条规则任一命中 → `spam_flag=1`，规则详见 `references/spam-rules.md`）：
   - **同句式**：同一 ASIN 内 ≥3 条评论的 5-gram 相似度 ≥0.90，且落在 7 天窗口内。
   - **集中时段**：同一 ASIN 48 小时内出现 ≥15 条 5 星，且其中 ≥80% 无 VP。
   - **无 VP + 极短**：`verified_purchase=0` 且正文词数 ≤12 且评分 =5，同时该 ASIN 此类评论占比 >25%。
   - 另记软信号（不单独判水军）：`helpful_votes=0` 且评论文本含 `received this product for free`/`in exchange for`（Vine 或测评），标 `incentivized=1`。
8. **变体归并**：`variant` 原文映射到父体维度（`Color`/`Size`），新增 `variant_key`（如 `Black|Large`）；无法解析的记 `variant_key=unknown`，占比 >30% 时该维度不做变体对比。
9. **时间衰减权重**：给每条评论算 `time_weight`：近 0–6 月 =1.0，6–12 月 =0.7，12–24 月 =0.4。权重列写入 CSV，供 `voc-mining` 加权。
10. **质量核验**：抽 50 条人工核对字段；抓取星级分布与页面直方图对比。
11. **落盘**：`reviews.csv`（清洗后分析集）、`reviews_raw.csv`（原始全量含重复与水军）、`sample_manifest.md`、`review_quality.md`。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 抽样标准 | 近 12 个月每 ASIN | ≥300 条（`full`）；100–299（`thin`，标 C）；<100（`insufficient`，标 D） |
| 全批上限 | 单次运行 | ≤5000 条，超限按 `rating_count` 降序截断 |
| 单 ASIN 上限 | 页数 / 条数 | 40 页 / 400 条 |
| 时间窗 | 默认近 12 个月 | 起点 = 运行日 − 365 天；扩窗到 24 个月时必须标 C |
| 星级校验 | 抓取分布 vs 页面直方图 | 各星级偏差 ≤3 个百分点 |
| 水军率 | `spam_flag=1` 条数 ÷ 该 ASIN 分析集 | >15% → 该 ASIN 评论不得用于情感结论，只做定性引用 |
| 重复率 | `dup_group` 覆盖条数 ÷ 原始条数 | >25% → 该 ASIN 标「评论异常」，人工复核 |
| VP 占比 | `verified_purchase=1` ÷ 分析集 | <70% → 该 ASIN 评论可信度降一级 |
| 时间衰减 | 权重 | 0–6 月 1.0 / 6–12 月 0.7 / 12–24 月 0.4 |
| 变体可用性 | `variant_key=unknown` 占比 | >30% → 不做变体维度分析 |
| 排序方式 | 必须 `Most recent` | 用 `Top reviews` 时整份语料标 C |

算例（真实量级）：23 个 ASIN，`rating_count` 50–4,800。

- 原始抓取 12,400 条（翻到 12 个月下界即停，5 个 ASIN 触 400 条上限）；去重剔除 1,860 条（重复率 15%）；水军剔除 940 条（7.6%）。
- 分析集 9,600 条，覆盖 18 个 ASIN；5 个 ASIN 因 `sample_status=insufficient` 只做定性引用。
- 星级分布 vs 页面直方图：5★ 偏差 1.2pp、1★ 偏差 0.8pp，通过（≤3pp）。
- 水军率最高 ASIN：18.4%（R2 命中 41 条，48 小时内 22 条五星、VP 占比 36%）→ 该 ASIN 4.7 分不可信，标「仅定性」。
- VP 占比中位 89%，最低 62%（1 个老品）→ 该 ASIN 可信度降一级。
- 结论行：`结论：可用 18 个 ASIN / 9,600 条，水军率中位 6.1%，2 个 ASIN 因水军率 >15% 剔除出情感分析`。

## 输出契约

- 落盘：`out/<run_id>/reviews.csv`、`out/<run_id>/reviews_raw.csv`、`out/<run_id>/sample_manifest.md`、`out/<run_id>/review_quality.md`
- `reviews.csv` 列：

| 列名 | 说明 |
|---|---|
| `review_id`（扩展） | 页面唯一标识 |
| `asin`（扩展） | 所属 ASIN |
| `rating`（扩展） | 1–5 |
| `review_date`（扩展） | YYYY-MM-DD |
| `verified_purchase`（扩展） | 1/0 |
| `variant`（扩展） | 原文变体串 |
| `variant_key`（扩展） | 归一化变体键 |
| `helpful_votes`（扩展） | 整数 |
| `review_title`（扩展） | 标题原文 |
| `review_text`（扩展） | 正文原文 |
| `has_image`（扩展） | 0/1 |
| `incentivized`（扩展） | 0/1，测评/Vine 软信号 |
| `spam_flag`（扩展） | 0/1 |
| `dup_group`（扩展） | 重复组号，空为无重复 |
| `cross_asin_dup`（扩展） | 0/1 |
| `time_weight`（扩展） | 0.4/0.7/1.0 |
| `evidence_grade` | A/B/C/D |
| `collected_at` | ISO 时间戳（含时区） |

- `review_quality.md` 必含：每 ASIN 的条数、VP 占比、水军率、重复率、星级偏差、`sample_status`。
- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：结论（可用 ASIN 数 / 总条数 / 水军率中位数）→ 证据（星级分布表 + 水军率 Top3 ASIN）→ 动作（例：「运营今天剔除 2 个水军率 >15% 的 ASIN，验收：分析集只剩 ASIN 数 ≥8、条数 ≥1500」）。

## 质检清单

- [ ] 首行数据可信度声明：排序方式 `Most recent`、时间窗、每 ASIN 条数、采集时段。
- [ ] 每 ASIN 有 `sample_status`，`thin`/`insufficient` 已在报告点名。
- [ ] 星级分布与页面直方图偏差 ≤3 个百分点（抽 5 个 ASIN）。
- [ ] 去重后条数与原始条数差异有解释（`dup_group` 统计表）。
- [ ] 水军三规则各自命中条数已分列，不合并成一个黑盒数字。
- [ ] 抽 50 条人工核对：星级、日期、VP、帮助票四项全对。
- [ ] `reviews.csv` 不含 `spam_flag=1` 与 `cross_asin_dup=1` 行（已分流到 raw）。
- [ ] 变体不可解析占比 >30% 的 ASIN 已在报告标注不做变体分析。

## 反模式

- **只抓第一页 10 条就分析**：首页是 `Top reviews`，全是高分长文，差评被压在后面。→ 正确：切 `Most recent` + 翻到 12 个月下界，≥300 条。
- **把 Vine 评论当真实用户**：带 `in exchange for honest review` 的 5 星拉高均分。→ 正确：标 `incentivized=1`，做情感分析时降权或单独出表。
- **删了水军不说**：读者以为样本是原始量。→ 正确：`review_quality.md` 写原始 N、清洗后 N、剔除原因分布。
- **用「平均星级」判断口碑**：4.3 分可能由 78% 五星 + 12% 一星构成，两极分化才是真相。→ 正确：永远同时给星级分布与 1 星占比。
- **跨 ASIN 混算均分**：把一个 12 条评论的新品与 4000 条的老品平均。→ 正确：按 ASIN 分层，聚合时按条数加权并标 `sample_status`。
