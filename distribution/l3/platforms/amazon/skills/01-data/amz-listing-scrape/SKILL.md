---
name: amz-listing-scrape
description: 抓取 Amazon 美国站详情页结构化字段（标题/五点/价格/变体/BSR/卖家数/上架时间/评分分布），统一字段名与失败重试口径，输出可进打分表的一行一 ASIN 快照。当用户提到「抓详情页」「listing 快照」「竞品数据」「抓价格」「抓 BSR」「变体数」「卖家数」「上架时间」或需要给选品打分准备竞品表时使用。
layer: 01-data
version: 1.0.0
inputs: [asin_list, keyword_universe.csv, category, marketplace, proxy_pool, session_cookies]
outputs: [listing_snapshot.csv, scrape_manifest.md, field_quality.md]
upstream: [amz-keyword-harvest]
downstream: [amz-review-harvest, market-sizing, competitor-deconstruct, profit-model]
---

# Amazon 详情页结构化抓取

## 何时用

- 已有关键词表，要按核心词取竞品 ASIN 集合，抓成一张能直接进四维打分的竞品表。
- 需要记录同一时间窗的前台快照。只有核实了完整可比总体时才回填正式竞争字段，搜索页样本范围另列。
- 判断类目是新品混战还是老品垄断：要看 `listed_since`、`seller_count`、`variation_count` 三个字段的分布。
- 竞品改价/改变体后要留证据：需要带时间戳的原值快照做前后对比。
- 不归这里：抓评论正文 → `amz-review-harvest`；算利润 → `05-product/profit-model`；判类目规模 → `02-market/market-sizing`；做竞品对比结论 → 04 层对比 skill（本 skill 只出数据，不出结论）。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `category` | 卖家指定 | 必需。用于选类目节点与 BSR 归属校验。 |
| `asin_list` | 卖家给 3–50 个，或上游关键词表 | 缺失：取 `keyword_universe.csv` 里 `keyword_tier=核心词` 的前 3 个词，各取第一页 48 自然位，合并去重后按出现频次取前 20 个 ASIN，标 B。 |
| `keyword_universe.csv` | `amz-keyword-harvest` 产出 | 缺失：只用 `asin_list`，不补 ASIN 集，`monthly_search_volume` 不写。 |
| `marketplace` | 默认 `amazon.com` | 缺省美国站；非美国站必须显式给，报告首行标注。 |
| `proxy_pool` | 住宅代理 ≥20 IP，或本机单 IP | 缺失：单 IP 串行，速率降到 1 请求/6s，预计 23 个 ASIN 用时 25–30 分钟。 |
| `session_cookies` | 无痕会话（不登录买家号） | 缺失：用未登录会话，`seller_count` 可见性下降，缺失率按实际记。 |
| `collected_at` | 本轮统一时间戳 | 必需。全批次共用同一个 `collected_at`，误差 ≤2 小时。 |

## 执行流程

1. **定采集环境**：收货邮编固定 `10001`（纽约），语言 `en-US`，货币 USD；浏览器视口 1440×900；不登录任何买家账号。
2. **定 ASIN 集**：核心词各取第一页 48 个自然位（跳过 `Sponsored`、`Sponsored Brands`、`Top Rated` 之外的推荐位），按出现次数排序取前 20；加卖家指定 3 个对标 ASIN，总 23 个上限。
3. **抓主图/标题/五点**：详情页 `#productTitle`、`#feature-bullets li`（取前 5 条，不足 5 条按实际）、主图第 1 张 URL。标题与五点原文保存，不截断。
4. **抓价格三件**：`buybox_price`（详情页购买框的可见报价）、`list_price`（划线价，无则空）、`coupon`（`Save x%` 或 `$x coupon` 文本）。`price_usd = buybox_price`。记录配送地是否验证、广告位、变体 ASIN、标称装量、有效主件数及兼容组。区间价与套件分列。
5. **抓变体**：展开变体选择器，取父体 ASIN、全部子体 ASIN、每个子体的属性值（颜色/尺寸）与该子体价格。`variation_count` = 子体数（父体不计）。
   - 只对 1 个代表子体抓完整详情（五点/BSR），其余子体只抓价格与属性，避免 23×N 次请求。
6. **抓 BSR**：详情页 Product information 表的 `Best Sellers Rank`，取前 2 行 → `bsr_main_rank`（主类目）、`bsr_category`（子类目名）、`bsr_sub_rank`（子类目排名）。类目数与 `category` 不一致时记 `bsr_mismatch=1`。
7. **抓上架时间**：`Date First Available` → `listed_since`（YYYY-MM）。该字段缺货变体常缺失，缺失记空不推算。
8. **抓卖家数**：`Other Sellers on Amazon` 区块的卖家条目数 + 1（BuyBox 卖家）；同时记 `fba_seller_count`（标注 `Fulfilled by Amazon` 的条目数）。区块不存在时 `seller_count=1`，记 `seller_source=buybox_only`。
9. **抓评分分布**：评论区的星级直方图（5→1 星百分比）+ `rating_avg` + `rating_count`。直方图缺失时只记 `rating_avg` 与 `rating_count`，`rating_dist_*` 留空。
10. **重试口径**：单字段抓取失败重试 3 次，间隔 10s / 30s / 90s；仍失败 → 该字段留空、`retry_count` 记 3；同一 ASIN 有 ≥3 个关键字段（价格/BSR/评分）失败 → `scrape_status=failed`，整行 `evidence_grade=C`。
11. **反爬处理**：出现验证码页 → 暂停该 IP 15 分钟，换 IP 重试；连续 3 个 IP 都出验证码 → 本轮停止，已抓数据封版并写 manifest `blocked=true`。
12. **交叉校验**：随机抽 3 个 ASIN，人工复核价格/BSR/卖家数三项；任一不符 → 该字段整列降级 C 并重抓该列。
13. **落盘**：`listing_snapshot.csv`、`scrape_manifest.md`（配送地、时间戳、成功率、失败 ASIN 列表）、`field_quality.md`（每个字段缺失率与证据等级）。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 一轮有效性 | 抓取成功率 | ≥95%（23 个至少 22 个成功），否则整轮作废重抓 |
| 字段可用性 | 单字段缺失率 | >20% → 该列整列降级 C，报告标注 |
| 证据等级 | 有采集时间戳的前台数据 | B；付费工具导出销量 A/B；推算 C；无数据 D |
| 变体判定 | `variation_count` | ≥3 多变体 / 1–2 单变体 / 0 无变体 |
| 卖家数分档 | `seller_count` | 1 独家 / 2–5 正常 / 6–15 跟卖多 / >15 价格战 |
| 上架时间分档 | 距采集日 | <6 月 新品 / 6–24 月 成长期 / >24 月 老品 |
| BSR 分档 | `bsr_main_rank` | ≤1000 头部 / 1001–10000 腰部 / >10000 长尾 |
| 评分分布校验 | 抓取直方图合计与 `rating_count` 偏差 | ≤2% 可用，>2% 标注不可用 |
| 价格口径 | 只取 BuyBox 实付 | 不取 list price、不取 Deal 倒计时价 |
| 采集时段 | 美东时间 | 工作日 09:00–17:00；Prime Day / 黑五前后 7 天不采样 |
| 同批一致性 | 全部 ASIN 的 `collected_at` 跨度 | ≤2 小时，超时拆批并各自标注 |

算例（真实量级）：品类 `kitchen-gadgets`，核心词 3 个，第一页 48 自然位并集得 34 个 ASIN，按出现频次取 20 + 对标 3 = 23 个。

- 成功 22 个（95.7%），1 个断货 `scrape_status=partial`，`seller_count` 缺失率 4%。
- 价格：中位 24.99 USD，区间 12.99–49.99；`coupon_pct` 非零 6 个（0.05–0.20）。
- 变体：`variation_count` 中位 4，最大 18（只抓最低/中位/最高 3 个子体价，标 `sampled=1`）。
- 卖家数：`seller_count` >6 的 5 个，其中 2 个 >15（判价格战，利润模型需压低 `price_usd` 预期）。
- 上架时间：`listed_since` 近 6 个月 7 个（新品混战），>24 个月 9 个（老品把持）。
- BSR：`bsr_main_rank` ≤1000 的 3 个，>10000 的 11 个（长尾为主）。
- 结论行：`结论：抓 23 个 ASIN 成功 22 个（95.7%），价格带 12.99–49.99 USD，卖家数 >6 的 5 个，2 个字段降级为 C`。

## 输出契约

- 落盘：`out/<run_id>/listing_snapshot.csv`、`out/<run_id>/scrape_manifest.md`、`out/<run_id>/field_quality.md`
- `listing_snapshot.csv` 列：

| 列名 | 来源模块 | 说明 |
|---|---|---|
| `asin`（扩展） | URL | 10 位 ASIN |
| `sku` | 卖家映射 | 无则空，下游按 asin 关联 |
| `product` | `#productTitle` | 原文标题 |
| `category` | 输入 | 品类 slug |
| `price_usd` | 有明确装量的 BuyBox | 页面报价 USD。成交价需要独立实付依据 |
| `list_price_usd`（扩展） | 划线价 | 无则空 |
| `coupon_pct`（扩展） | coupon 文本 | 0–1，无则 0 |
| `monthly_search_volume` | 上游词表 | 该 ASIN 主词月搜索量，无则空 |
| `sample_comparable_count` | 同批 ASIN 集 | 本批可比 ASIN 数。正式在售同款数需要共同总体 |
| `sample_top_review_count` | 本批最大值 | 仅同兼容规格样本最高评论数 |
| `top10_review_share_proxy` | 本批评论 | 0–1，评论代理标 C，销量集中度需另证 |
| `rating_avg`（扩展） | 评分区 | 1.0–5.0 |
| `rating_count`（扩展） | 评分区 | 条 |
| `rating_dist_5` 至 `rating_dist_1`（扩展） | 直方图 | 0–1 小数，共 5 列 |
| `variation_count`（扩展） | 变体选择器 | 子体数 |
| `bsr_main_rank`（扩展） | Product information | 主类目排名 |
| `bsr_sub_rank`（扩展） | Product information | 子类目排名 |
| `seller_count`（扩展） | Other Sellers | 含 BuyBox 卖家 |
| `fba_seller_count`（扩展） | Other Sellers | FBA 条目数 |
| `listed_since`（扩展） | Date First Available | YYYY-MM |
| `retry_count`（扩展） | 采集日志 | 0–3 |
| `scrape_status`（扩展） | 采集日志 | ok / partial / failed |
| `evidence_grade` | 判定 | A/B/C/D |
| `collected_at` | 采集 | ISO 时间戳（含时区） |

- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：结论（抓了几个、成功率、几个字段降级）→ 证据（价格带分布 1 行、变体数中位数、卖家数 >6 的 ASIN 数）→ 动作（今天做的事：例「运营当天把 seller_count >6 的 4 个 ASIN 加入监控表，验收：表内每条有跟卖数与最近改价时间」）。

## 质检清单

- [ ] 首行数据可信度声明：站点、邮编 10001、采集时段、`collected_at` 跨度。
- [ ] 成功率 ≥95%，失败 ASIN 在 manifest 列名并标 C。
- [ ] `price_usd` 全部为 BuyBox 实付价，抽查 3 条与页面一致。
- [ ] `variation_count` 与变体选择器子体数一致，父子体关系记录在 `raw/variants_<asin>.json`。
- [ ] BSR 主/子类目与 `category` 一致，`bsr_mismatch` 已统计。
- [ ] 评分直方图偏差 ≤2%，超差的 ASIN 已标注。
- [ ] 单字段缺失率表已出，>20% 的列已降级并在结论行提及。
- [ ] 无验证码页残留导致的空行（`scrape_status=failed` 行不得进打分表）。

## 反模式

- **拿 list price 当售价**：划线价常高于实付 20–40%，利润算出来虚高。→ 正确：`price_usd` 只取 BuyBox 实付，划线价单独列。
- **不同天抓的数据混一张表**：周一价格与周五价格混算，价格带结论失真。→ 正确：全批 `collected_at` 跨度 ≤2 小时，超时拆批。
- **只抓父体价格就填全变体**：子体价差可达 2 倍，`price_usd` 会错。→ 正确：逐子体抓价，父体只做关联。
- **抓不到就估一个数**：填经验值又不标等级，下游当实测用。→ 正确：留空 + `scrape_status=partial` + 证据等级 C，让下游用降级规则。
- **把推荐位 ASIN 当自然位**：`Sponsored`、`Customers also bought` 混入，`competitor_count` 虚高。→ 正确：只取自然搜索结果位，模块来源写进 manifest。
