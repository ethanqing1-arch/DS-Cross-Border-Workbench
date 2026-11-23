---
name: amz-keyword-harvest
description: 采集 Amazon 美国站关键词（搜索下拉/ABA 报告/竞品 ASIN 反查/SP 搜索词报表）并分层为核心词/属性词/场景词/长尾词，输出月搜索量与竞争度字段。当用户提到「关键词采集」「关键词挖掘」「挖词」「反查流量词」「ABA 搜索词」「下拉词」「搜索词报表」或需要建词库、定主词时使用。
layer: 01-data
version: 1.0.0
inputs: [seed_keywords, asin_list, aba_report_path, sp_search_term_path, category, marketplace, FX]
outputs: [keyword_universe.csv, keyword_tiers.md, negative_terms.csv, collection_manifest.md]
upstream: []
downstream: [amz-listing-scrape, amz-review-harvest, market-sizing, market-trend, demand-priority]
---

# Amazon 关键词采集与分层

## 何时用

- 新品类冷启动，需要 ≥150 个可用词的词库：主词 1–3 个 + 属性词 8–15 个 + 长尾词 ≥60 个。
- 已有 listing 想查「到底靠哪些词进流量」，要对比自家 ASIN 与竞品的流量词差异。
- 手里有 ABA 搜索词报告或 SP 搜索词报表，要洗成能打分、能进标题的词表（去品牌词、去 ASIN 词、去无效词）。
- 判断一个主词是红海还是蓝海：要 `monthly_search_volume`、`competitor_count`、`top10_share` 三个字段。
- 不归这里：判断类目整体规模与天花板 → `02-market/market-sizing`；从评论挖痛点 → `03-demand/voc-mining`；把词写进标题 → `06-delivery` 层上架 skill；判断某词广告值不值得投 → `06-delivery` 层广告 skill。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `category` | 卖家指定（如 `kitchen-gadgets`） | 必需。缺失直接停，不让 agent 猜品类。 |
| `seed_keywords` | 卖家口述 3–10 个，或竞品标题前 3 个名词 | 缺失：取该类目 Best Sellers 前 20 个 listing 标题，按词频取前 5 个名词当种子词，标 C。 |
| `asin_list` | 卖家给 3–20 个竞品 ASIN | 缺失：用种子词搜索，取第一页 48 个自然位（不含 Sponsor）的前 10 个 ASIN，标 B。 |
| `aba_report_path` | 品牌后台 Brand Analytics 搜索词报告 CSV（周表） | 缺失：跳过步骤 3，`aba_rank` 留空，`monthly_search_volume` 仅采用同站同词的 Amazon 站内量级估算，附原始导出和方法，标 C。缺可信估算则「无源」，留空。 |
| `sp_search_term_path` | 广告后台搜索词报告 CSV（近 60 天） | 缺失：跳过步骤 5，词表只来自下拉+ABA+反查，标 C。 |
| `marketplace` | 默认 `amazon.com`（`marketplace_id=ATVPDKIKX0DER`） | 缺省美国站；非美国站时在报告首行写明站点与邮编。 |
| `FX` | 全局 7.15 | 本 skill 不做换算，仅透传给下游。 |

## 执行流程

1. **建 run 目录**：`out/<run_id>/`，`run_id = YYYYMMDD-HHMM-<category-slug>`；`raw/` 存原始响应，`logs/` 存请求失败记录。
2. **拉搜索下拉词**：请求 `completion.amazon.com/api/2017/suggestions`，参数 `mid=ATVPDKIKX0DER`、`alias=aps`、`prefix=<前缀>`。
   - 前缀集 = 种子词本身 + 26 个字母后缀（`<seed> a` 到 `<seed> z`）+ 3 个修饰前缀 `<seed> best` / `<seed> for` / `<seed> with`，共 30 个前缀。
   - 每前缀取返回前 10 条，记录 `suggest_position`（1–10）。请求间隔 1.5–3s 随机；失败重试 2 次（退避 5s、15s）。
   - 单轮失败率 >20% → 该轮下拉词整体标 C，并在 manifest 记录失败前缀列表。
3. **解析 ABA 报告**：取最近 4 个完整周（周一–周日），按 `search term` 聚合，取 `search frequency rank` 中位数。
   - 保留 rank ≤ 300000 的词；同词跨周取中位数排名。
   - `monthly_search_volume` = 该排名对应周搜索量 × 4.33（周→月）；报告只有排名时，需同站、同时间窗、有真实搜索量的同类目校准集才能估量并标 C。保留校准集与误差。否则只输出排名。
   - 剔除：品牌词、ASIN 型词（`^b0[a-z0-9]{8}$`）、单字符词、纯数字词。
4. **竞品 ASIN 反查**：对 `asin_list` 每个 ASIN 取三处文本——标题、五点、详情页底部 related searches 模块（8–16 个词）。
   - 标题+五点做 n-gram 抽取（n=1..4），保留在 ≥3 个 ASIN 出现的短语 → 共性词，记 `asin_coverage`。
   - 前台页面抓不到的 ASIN 直接跳过，不猜词；跳过数 >30% 则该源标 C。
5. **清洗 SP 搜索词报表**：时间窗固定 60 天，按 `Customer Search Term` 聚合。
   - 保留：点击 ≥10 且（订单 ≥1 或 CVR ≥5%）。
   - 剔除：`asin=` 型、品牌词、`relevance_ratio` <0.4 的词。
   - 另出否定词表：点击 ≥20 且 订单 = 0。
6. **合并去重**：全部转小写、去标点、压空格；单复数合并（`-s`/`-es`/`-ies`）；`&`→`and`；同义词按 `references/keyword-tier-rules.md` 的表合并（如 `wireless`=`cordless`）。保留 `source_flags`（`suggest|aba|reverse|sp` 任意组合）。
7. **相关性核验**：对 `monthly_search_volume` ≥5000 的词，取该词搜索结果第一页 48 个自然位，数同品类 ASIN 数 ÷ 48 = `relevance_ratio`。
   - <5000 的词不做全页核验，用同类目 Top10 标题命中率代理，标 C。
8. **分层**：按「判定口径」表的四层规则；一词只归一层，优先级 核心 > 场景 > 属性 > 长尾，次层写入 `secondary_tier`（扩展）。
9. **打竞争度字段**：先登记站点、可比规格和去重 ASIN 集合 `cohort`。输出该共同总体的在售同款数、最高评论、前 10 销量占总体销量。首屏自然位计数另存 `first_page_comparable_count`，评论集中度另存 `top10_review_share_proxy`。缺共同总体或销量时正式字段留空，并给补数路径。
10. **算词级竞争指数**：`competition_index = 100 × (0.5×log1p(competitor_count)/log1p(500) + 0.3×log1p(top_review_count)/log1p(10000) + 0.2×top10_share)`，截断到 0–100。此指标只用于词库排序，不替代规范 4.2 的竞争压力维度。
11. **落盘三件**：`keyword_universe.csv`、`keyword_tiers.md`、`negative_terms.csv`；manifest 写采集时间、邮编、自然位口径、各源成功率。
12. **出结论行**：`结论：可用词 N 个（核心 a / 属性 b / 场景 c / 长尾 d），主词建议 X，红海词 Y 个`。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 核心词 | 词数 ≤3 + 月搜索量 ≥50000 + 相关性 ≥0.8 | 每品类只留 1–3 个 |
| 属性词 | 命中材质/尺寸/颜色/容量/功率/数量词典，词数 ≤5 | 保留 8–15 个 |
| 场景词 | 命中人群/场景/节日/时间词典（`for kids`、`outdoor`、`christmas`、`small apartment`） | 保留 5–20 个 |
| 长尾词 | 词数 ≥4 且 月搜索量 500–20000 | 占词表 ≥40% |
| 词库规模 | 总词数 ≥150 | <150 时补 3 个种子词重跑一轮 |
| 相关性 | `relevance_ratio` ≥0.70 有效 / 0.40–0.69 观察 / <0.40 剔除 | 分三档 |
| 竞争指数 | `competition_index` <40 低 / 40–65 中 / >65 高 | 三分档 |
| 垄断度 | `top10_share` <0.45 分散 / 0.45–0.65 集中 / >0.65 寡头 | 沿用规范 4.3 |
| 红海词判定 | 核心词 `top10_share` >0.65 且 `top_review_count` >2000 | 不给主词位，只做长尾侧翼 |
| 蓝海词判定 | `monthly_search_volume` 5000–30000 且 `competitor_count` <50 且 `top_review_count` <200 | 优先做标题长尾位 |
| 数据可信度 | 每行标 A/B/C/D；D 级占比 >30% | 结论降级为「观察」 |

算例（真实量级，可照抄格式）：类目 `kitchen-gadgets`，种子词 `silicone mat`。

- 下拉 30 个前缀返回 268 条，去重 141 条；ABA 近 4 周保留 rank ≤300000 的 96 词；10 个 ASIN 反查得共性词 38 个；SP 60 天报表保留 22 词。四源并集 187 词。
- `silicone mat for kitchen`：月搜 62,000，48 位同款 41，最高评论 8,400，`top10_share` 0.71（销量口径，B 级）→ 命中核心词但判寡头，不给主词位。
- `silicone mat for small apartment`：月搜 3,100，同款 12，最高评论 320，`top10_share` 0.38 → 场景词 + 蓝海，进标题后段。
- 词级 `competition_index`：前者 78（高）、后者 31（低），排序时蓝海词优先。
- 结论行：`结论：可用词 164 个（核心 2 / 属性 11 / 场景 14 / 长尾 137），主词建议 silicone mat（top10_share 0.52，需价格带错位），红海词 9 个只做侧翼`。

## 输出契约

- 落盘：`out/<run_id>/keyword_universe.csv`、`out/<run_id>/keyword_tiers.md`、`out/<run_id>/negative_terms.csv`、`out/<run_id>/collection_manifest.md`
- `keyword_universe.csv` 列（与 `engine/score.py` 对齐的字段逐字一致）：

| 列名 | 说明 |
|---|---|
| `keyword`（扩展） | 清洗后的词（小写、单数化） |
| `keyword_tier`（扩展） | 核心词/属性词/场景词/长尾词 |
| `secondary_tier`（扩展） | 次层归属，无则空 |
| `monthly_search_volume` | Amazon 同站同词月搜索量，次/月。记录时间窗、原始导出和口径 `amazon_search_monthly`。 |
| `competitor_count` | 可比总体的在售同款数，首屏样本数另存。 |
| `top_review_count` | 同一可比总体内的最高评论数。 |
| `top10_share` | 同一可比总体内前 10 销量占比 0–1。评论代理分列。 |
| `relevance_ratio`（扩展） | 同品类 ASIN 占比 0–1 |
| `competition_index`（扩展） | 0–100，词库排序用 |
| `source_flags`（扩展） | `suggest,aba,reverse,sp` 组合 |
| `suggest_position`（扩展） | 下拉词位置 1–10，非下拉词留空 |
| `aba_rank`（扩展） | ABA 搜索频率排名 |
| `asin_coverage`（扩展） | 出现该词的竞品 ASIN 数 |
| `evidence_grade` | A/B/C/D |
| `collected_at` | ISO 时间戳（含时区） |

- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：先结论行（可用词数+主词建议）→ 再证据（核心词表 3 行 + 蓝海词表 5 行）→ 再动作（今天做的事：谁、做什么、多久、验收标准，例：「运营 2 小时内把 3 个主词+12 个属性词写进标题草稿，验收：标题含全部核心词且 ≤200 字符」）。

## 质检清单

- [ ] 首行数据可信度声明已写：采集日期、站点、邮编 10001、自然位口径（第一页 48 位不含广告）。
- [ ] 每个词有 `evidence_grade`，D 级行数占比 ≤30%。
- [ ] `keyword_tier` 与 `secondary_tier` 归属符合词典三条件，抽 20 行人工复核无错分。
- [ ] 核心词 ≤3 个，且每个 `relevance_ratio` ≥0.8、`monthly_search_volume` ≥50000。
- [ ] `competitor_count`、`top_review_count`、`top10_share` 出自同批次采集，时间戳间隔 ≤2 小时。
- [ ] 无品牌词、无 ASIN 型词残留（抽 20 行）。
- [ ] 词表 ≥150 行，长尾词占比 ≥40%。
- [ ] Google Ads、lingxiao 站外词量、下拉建议和未校准排名仅用于线索，正式月搜缺口已标无源。

## 反模式

- **只跑下拉词就交**：下拉词没有量级，全部只能标 C，且漏掉 ABA 里的高转化长尾。→ 正确：至少两源交叉（下拉 + ABA 或 反查），单源词表在结论行注明「仅方向，不可定主词」。
- **把品牌词当核心词**：`anker charger` 月搜 8 万但转化归品牌。→ 正确：品牌词单独出表 `brand_terms.csv`，不进主词，也不进标题。
- **用搜索结果数当 `competitor_count`**：那是全站 listing 数（几十万），必然判红海。→ 正确：只数第一页 48 个自然位里同款，口径写进 manifest。
- **让模型「感觉」分层**：同一个词两次运行归到不同层。→ 正确：词典命中 + 词数 + 量级三条件，规则写在 `references/keyword-tier-rules.md`。
- **`top10_share` 用评论占比却不标注**：把 C 级代理数据当 A 级销量占比用，直接推翻垄断度结论。→ 正确：评论代理单列且标 C，留空销量占比字段。
