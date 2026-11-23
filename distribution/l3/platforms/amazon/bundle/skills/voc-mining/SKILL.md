---
name: voc-mining
description: 跨平台 VOC 挖痛点——合并 Amazon 评论、Q&A、Reddit 讨论、TikTok 评论四源，聚成 Top 10 痛点并给情感极性、提及频次、可改进性与原文引用。当用户提到「痛点」「VOC」「用户抱怨什么」「差评原因」「Q&A 在问什么」「评论挖需求」「找改进点」时使用。
layer: 03-demand
version: 1.0.0
inputs: [reviews.csv, qa_corpus, reddit_corpus, tiktok_comments, category, review_window_months]
outputs: [pain_points.csv, voc_top10.md, quotes_bank.csv]
upstream: [amz-review-harvest, web-trend-scan]
downstream: [demand-priority, negative-review-gap, jtbd-map]
---

# 跨平台 VOC 痛点挖掘

## 何时用

- 想找差异化切入点：竞品评分 4.2，要先知道那 0.8 分丢在哪三条痛点。
- 新品定义阶段：四源合并出 Top 10 痛点，作为产品定义与卖点的输入。
- 已有供应商报价，要判断「这个改进值不值得加钱」：看痛点的可改进性与提及频次。
- Q&A 里反复出现同一个问题（如「能不能进洗碗机」），说明详情页信息缺失或产品设计有缺口。
- 不归这里：给痛点排优先级、定 P0/P1/P2 → `03-demand/demand-priority`；拆使用场景 → `03-demand/jtbd-map`；抓评论本身 → `01-data/amz-review-harvest`；定包装文案 → `06-delivery` 层。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `reviews.csv` | `amz-review-harvest`（已去重去水军） | 缺失：先跑上游；不得用未清洗评论，否则水军句式会变成假痛点。 |
| `qa_corpus` | 详情页 Q&A 区（问题+回答全文，JSONL） | 缺失：只用三源，`source_mix` 缺 `qa`，结论标 C。 |
| `reddit_corpus` | `web-trend-scan` 的 Reddit 抓取（帖子+评论） | 缺失：只用站内源，标 C，并注明「无站外验证」。 |
| `tiktok_comments` | 话题下 Top 20 视频的评论（≥200 条） | 缺失：跳过，标 C。 |
| `category` | 输入 | 必需：决定痛点类目树（见 `references/cluster-taxonomy.md`）。 |
| `review_window_months` | 默认 12 | 必须与上游一致；不一致时整份语料标 C。 |
| `min_mentions` | 默认 30 | 低于 30 的痛点不进 Top 10，只进 `quotes_bank.csv` 备查。 |

## 执行流程

1. **装载四源**：每源统计条数、时间跨度、语言。单源 <100 条 → 该源标 `thin`，权重减半。
2. **统一成句级语料**：每条评论/帖子/回答按句号、问号、感叹号、换行切句；去 URL、去 emoji、去 `#tag`、去全大写强调；保留否定词（`not`、`no`、`never`、`doesn't`）。
3. **抽痛点候选**：两条路并行——
   - 词典路：命中 `references/cluster-taxonomy.md` 的痛点词根（`leak`、`rust`、`flimsy`、`too small`、`hard to clean`、`stopped working`、`smell`、`broke after`）；
   - 开放路：对 3–6 gram 做频次统计，取出现 ≥20 次且不在停用词表的短语。
4. **聚类**：把候选短语与所在句子做向量化，层次聚类（HAC，余弦距离阈值 0.35）；每簇取中心句 + 最高频短语作 `cluster_label`。
   - 簇内 <5 条句子的合并到最近簇或丢弃。
   - 单簇跨 >3 个语义方向时（如「尺寸问题」混了「太大」与「太小」）强制再拆，拆成 `size_too_small` / `size_too_large`。
5. **算提及频次**：`mention_count` = 簇内去重后的句子数（同一用户同一 ASIN 只说一次算 1）。同时算时间加权频次 `mention_weighted = Σ time_weight`（用上游 `time_weight`）。
6. **算源覆盖**：`source_mix` 记四源各自条数；`asin_coverage` = 提及该痛点的不同 ASIN 数；`subreddit_coverage` = 提及的 subreddit 数。
7. **算情感极性**：对簇内句子做情感打分，`sentiment_polarity` = 均值（−1 到 +1）。规则：含否定 + 负面词（`not durable`）→ 负；含 `but` 转折时以转折后为主。
8. **算强度**：`severity` 1–5，按四条打分取均值后四舍五入——
   - 是否导致退货/换货（提及 `returned`/`refund`/`threw away`）=5，否则按情绪词强度给 1–4；
   - 是否影响核心功能（`doesn't work`/`leak`/`broke`）=+1，上限 5；
   - 是否只是外观/包装（`color`/`box`）=上限 3。
9. **算可改进性**：`improvable_score` 0–10，按 `references/cluster-taxonomy.md` 的五项 rubric 打分（结构可改性、成本增量、供应链可得性、专利风险、验证难度）。
10. **排 Top 10**：按 `mention_weighted × severity` 降序；同分时 `asin_coverage` 高者优先；`mention_count` <30 的不进榜。
11. **取证**：每个痛点抽 3 条原文（优先：不同 ASIN、不同源、`helpful_votes` 最高），写 `quotes_bank.csv`，保留原文不改写。
12. **落盘 + 结论行**：`pain_points.csv`、`voc_top10.md`、`quotes_bank.csv`。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 进榜门槛 | `mention_count` 与 `asin_coverage` | ≥30 条 且 ≥3 个 ASIN，否则只进备查库 |
| 跨源共性 | `source_mix` 有效源数 | ≥2 源才算「跨平台共性」；单源标 C |
| Top 10 排序 | `mention_weighted × severity` | 降序，同分比 `asin_coverage` |
| 情感极性 | `sentiment_polarity` | ≤−0.30 负面 / −0.29~+0.29 中性 / ≥+0.30 正面 |
| 强度分 | `severity` | 1 轻微 / 3 影响体验 / 5 导致退货或功能失效 |
| 可改进性 | `improvable_score` | ≥7 可产品化（进产品定义）/ 4–6 需验证 / ≤3 只能靠文案规避 |
| 语料充足 | 总句数 | ≥1500 句才出 Top 10；800–1499 出 Top 5 并标 C；<800 只做定性 |
| 簇最小规模 | 簇内句子数 | <5 条合并到最近簇，合并失败则丢弃 |
| 引用去重 | 同一用户同一 ASIN 重复句 | 只计 1 次，原文可保留多条但 `mention_count` 不重复加 |
| 单源权重 | `thin` 源 | 条数 <100 时权重 ×0.5 |
| 引用规范 | 每痛点原文数 | 3 条，且来自 ≥2 个 ASIN |
| 时间一致 | 四源时间窗 | 与 `review_window_months` 偏差 ≤1 个月 |

算例（真实量级）：`kitchen-gadgets`，四源合计 9,600 条评论 + 1,180 条 Q&A + 620 条 Reddit + 840 条 TikTok 评论，切句后 28,400 句。

- 候选短语 1,320 个，HAC 聚成 46 簇，过 `mention_count` ≥30 的 12 簇，取 Top 10。
- `leaks_at_lid_seal`：`mention_count` 214（weighted 168），`asin_coverage` 11，`source_mix` review:168;qa:31;reddit:15，极性 −0.62，`severity` 5，`improvable_score` 9 → 榜首。
- `hinge_cracks_in_3_months`：132 / 9 个 ASIN / 极性 −0.71 / 强度 5 / 可改进 7。
- `overpriced_vs_alternatives`：64 / 12 个 ASIN / 极性 −0.28 / 强度 3 / 可改进 2 → 频次不低但不可改进，标「只能靠定价」。
- 语料 28,400 句 >1,500，判 `full`；`thin` 源 0 个。
- 结论行：`结论：Top 3 为盖口漏水、铰链 3 个月开裂、尺寸偏小；其中 2 项可产品化（可改进性 9 / 7），1 项只能靠定价`。

## 输出契约

- 落盘：`out/<run_id>/pain_points.csv`、`out/<run_id>/voc_top10.md`、`out/<run_id>/quotes_bank.csv`
- `pain_points.csv` 列：

| 列名 | 说明 |
|---|---|
| `pain_point_id`（扩展） | `PP-01` 起按 Top 排序顺序编号 |
| `cluster_label`（扩展） | 英文短标签，如 `leaks_at_lid_seal` |
| `cluster_label_cn`（扩展） | 中文短标签，如「盖子密封处漏水」 |
| `mention_count`（扩展） | 去重句数 |
| `mention_weighted`（扩展） | 时间加权句数 |
| `source_mix`（扩展） | 如 `review:180;qa:42;reddit:26;tiktok:9` |
| `asin_coverage`（扩展） | 提及的不同 ASIN 数 |
| `sentiment_polarity`（扩展） | −1.00 ~ +1.00 |
| `severity`（扩展） | 1–5 |
| `improvable_score`（扩展） | 0–10 |
| `quote_1` / `quote_2` / `quote_3`（扩展） | 原文引用（含 ASIN 与星级） |
| `evidence_grade` | A/B/C/D |
| `collected_at` | ISO 时间戳（含时区） |

- `voc_top10.md` 必含：Top 10 表（痛点 / 频次 / 强度 / 极性 / 可改进性 / 覆盖 ASIN 数）、每痛点 3 条原文、四源占比。
- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：结论（Top 3 痛点 + 是否可产品化）→ 证据（Top 10 表）→ 动作（例：「产品今天把 PP-01 的密封圈从 EVA 改硅胶，成本 +0.35 USD，验收：打样后 30 次倒置不漏」）。

## 质检清单

- [ ] 首行数据可信度声明：四源条数、时间窗、`thin` 源列表、语料总句数。
- [ ] 每个痛点 `mention_count` ≥30 且 `asin_coverage` ≥3（Top 10 内）。
- [ ] 每痛点 3 条原文，可点回原 ASIN/帖子，未改写。
- [ ] 正负极性方向人工抽检 20 句，错判 ≤2 句。
- [ ] 拆分检查：「尺寸」「质量」这类大簇已拆成方向相反的细簇。
- [ ] 水军评论未进语料（`spam_flag=0` 才入）。
- [ ] `improvable_score` 每项 rubric 打分有记录（`raw/voc_rubric.md`）。
- [ ] Top 10 里至少 3 个痛点的 `improvable_score` ≥7，否则结论写「可改进空间有限」。

## 反模式

- **只看差评**：4–5 星里藏着「好用，但有个小问题」，那是最有价值的改进点。→ 正确：全星级入语料，按星级分层统计，`but` 转折句单独加权。
- **把「质量差」当一个痛点**：粒度太粗，无法转成产品参数。→ 正确：拆到 `stitching_comes_loose`、`plastic_cracks_at_hinge` 这一级。
- **只用一个平台**：Amazon 评论是已购用户，Reddit 是未购但挑剔的用户，两者痛点不同。→ 正确：≥2 源，单源标 C。
- **频次高就排第一**：`too expensive` 频次最高但不可改进。→ 正确：排序乘 `severity`，且 `improvable_score` ≤3 的标注「只能靠定价/文案」。
- **改写引用**：把用户原话润色成卖点句，失去证据力。→ 正确：原文照抄，含 ASIN、星级、日期。
