---
name: web-trend-scan
description: 补齐站外需求趋势（Google Trends / TikTok 话题 / Reddit 讨论 / 独立站竞品），算趋势斜率与季节性系数，判品类在上升还是衰退。当用户提到「趋势」「季节性」「淡旺季」「Google Trends」「TikTok 有没有人聊」「Reddit 讨论」「独立站竞品」「这个品还能火多久」时使用。
layer: 01-data
version: 1.0.0
inputs: [keywords, category, subreddit_list, tiktok_hashtags, dtc_site_list, window_months, marketplace]
outputs: [trend_series.csv, seasonality.md, offsite_signals.md]
upstream: [amz-keyword-harvest]
downstream: [demand-priority, market-trend, market-sizing]
---

# 站外趋势扫描与季节性系数

## 何时用

- Amazon 站内搜索量平稳，但想确认「站外是不是已经在起量」（TikTok 带火、Reddit 讨论变多）。
- 要备货，需要知道旺季在哪几个月、峰值是均值的几倍。
- 判断一个品是「长期需求」还是「一波流」：看 5 年趋势线的斜率，不看单月峰值。
- 站内 ABA 量级太小（月搜 <3000），需要站外信号补需求强度证据。
- 不归这里：算类目 GMV / TAM → `02-market/market-sizing`；挖痛点 → `03-demand/voc-mining`；抓 Amazon 站内关键词 → `amz-keyword-harvest`；做 12 个月站内搜索指数、CAGR、生命周期定位 → `02-market/market-trend`（本 skill 只出站外信号与季节系数，不替代站内曲线）。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `keywords` | `keyword_universe.csv` 的 `keyword_tier=核心词` 前 3 个 | 缺失：用 `category` 名 + 2 个同义词，标注「词由品类名推断」标 C。 |
| `category` | 输入 | 必需。用于选 subreddit 与 DTC 站点集。 |
| `subreddit_list` | 默认按品类映射（见 `references/source-playbook.md`） | 缺失：用默认映射表，标 B。 |
| `tiktok_hashtags` | 默认 = 核心词 + `#<category>tok` | 缺失：用核心词小写去空格，标 C。 |
| `dtc_site_list` | 20 个独立站（品牌站/Shopify 站） | 缺失：用 Google `site:myshopify.com <核心词>` 取前 20 个结果，标 B。 |
| `window_months` | 默认 60（5 年），短期用 12 | 缺省 60；只给 12 时趋势斜率置信降为 C。 |
| `marketplace` | 默认 `amazon.com` → 地理 US | 非美国站时 Google Trends 的 `geo` 同步改（UK/DE/JP）。 |

## 执行流程

1. **词表映射**：每个核心词配 2 个同义词（如 `silicone mat` / `silicone placemat` / `silicone table mat`），三词在 Google Trends 同一查询里对比取均值，避免单词量级噪声。
2. **拉 Google Trends**：`geo=US`，`date=today 5-y`（月粒度）与 `today 12-m`（周粒度）各一次；`gprop=` 空（网页搜索）。
   - 导出 CSV：`date`、`interest_value`（0–100，同一查询内相对值）。
   - 5 年序列做趋势拟合；12 个月序列做季节形状。
3. **拉 TikTok 话题**：对每个 hashtag 取三项——累计播放量、近 30 天新增视频数、近 30 天 Top 10 视频平均点赞。用话题页或第三方（TikTok Creative Center）导出。
4. **拉 Reddit**：对每个 subreddit 用搜索接口取近 90 天帖子（`q=<核心词>`），记帖子数、评论数、平均赞、Top 5 帖子标题与链接；同时取近 12 个月按月帖子数。
5. **扫独立站**：20 个 DTC 站各取：是否在售同类品、价格带（min/median/max）、近 90 天新品数（collection 页按 `new` 排序取前 20 的日期分布）、评论总数（若有）、是否投 FB/Google 广告（用公开广告库查品牌名）。
6. **算趋势斜率**：对 5 年月序列做 OLS：`interest_t = a + b×t`（t 为月份序号）。
   - `trend_slope_pct = b / mean(interest) × 100`，单位 %/月。
   - 同时算 12 个月斜率，两者方向相反时（5 年升、12 月降）判「长期升、短期回落」，写入 `slope_conflict=1`。
7. **算季节性系数**：用 5 年同月均值 ÷ 全序列均值 = `seasonality_index[month]`（1–12 月各一个）。
   - 峰值月 `peak_month` = argmax；谷值 `trough_month` = argmin。
   - 季节振幅 `season_amplitude = max / min`。
8. **算站外热度合成分**（0–100，仅用于横向比较，不进打分表）：
   `offsite_score = 40×norm(tiktok_30d_views) + 30×norm(reddit_90d_posts) + 30×norm(dtc_listing_growth)`，各分项用同类目 10 个参照品做 min-max 归一。
9. **交叉验证**：站外上升（slope ≥+3%/月）但 Amazon 站内 `monthly_search_volume` 环比下降 >15% → 标「站内外背离」，不出「上升」结论，改为「观察 4 周」。
10. **落盘**：`trend_series.csv`（长表）、`seasonality.md`（12 个月系数表 + 备货建议）、`offsite_signals.md`（四源明细 + 链接）。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 趋势斜率 | `trend_slope_pct` | >+3%/月 上升 / −3%~+3% 平稳 / <−3%/月 下降 |
| 斜率显著性 | OLS 的 R² | ≥0.50 才可下方向结论；<0.50 判「无趋势」 |
| 季节性强度 | `seasonality_index` 峰值 | ≥1.30 强季节 / 1.10–1.29 弱季节 / <1.10 无明显季节 |
| 季节振幅 | max ÷ min | ≥2.0 强波动（备货风险高）/ 1.4–1.99 中等 / <1.40 平稳 |
| 备货系数 | 峰值前 2 个月备货量 | 基准月销 × 峰值 index × 1.15（安全垫） |
| 站外热度 | `offsite_score` | ≥70 高 / 40–69 中 / <40 低 |
| 数据源数量 | 有效源（有数据且未降级） | ≥2 个才能出方向结论；=1 个只能「观察」 |
| TikTok 起量 | 近 30 天视频数 ÷ 前 30 天 | ≥1.5 判「站外起量」/ 0.8–1.49 平 / <0.8 退 |
| Reddit 讨论度 | 近 90 天帖子数 | ≥30 有讨论 / 10–29 弱 / <10 无 |
| DTC 供给 | 20 站中在售同类品站数 | ≥8 供给拥挤 / 3–7 有验证 / <3 需求未验证 |
| 站内外背离 | 站外斜率与站内环比 | 方向相反且幅度 >15% → 只出「观察」，不出「上升/下降」 |
| Trends 零值处理 | 5 年序列中 0 值月份占比 | >30% → 该词降级 C，改用 `offsite_score` 辅助 |
| TikTok 单条爆款 | 单条视频播放量 | >500 万先剔除再算 Top 10 均值，剔除数 >3 条则该源标 C |
| 参照集可比性 | 价格带差异 | 参照品价差 ≤1.5 倍，超出则归一化无效，重选参照集 |
| 证据等级 | 平台导出原始数据 B；第三方指数 C；推断 D | 单源结论不得高于 C |

算例（真实量级）：品类 `kitchen-gadgets`，核心词 `silicone mat`，`geo=US`，5 年月序列 60 个点。

- OLS：`b = 0.42`（指数/月），`mean(interest) = 46.8` → `trend_slope_pct = +0.90%/月`，`R² = 0.31` → 判「无趋势」（R² <0.50），不出「上升」结论。
- 12 个月序列：`b = 1.8`，`mean = 52.4` → `+3.4%/月`，与 5 年方向一致但幅度小，标「短期回升，长期平稳」。
- 季节系数：11 月 1.62、12 月 1.94、1 月 0.71、7 月 0.83；`peak_month=12`，`trough_month=1`，`season_amplitude = 2.73` → 强季节 + 强波动，备货按 12 月 index 1.94×1.15 = 2.23 倍。
- 四源：TikTok 近 30 天视频 1,240 条（环比 1.18，未达 1.5 起量线）；Reddit 90 天 41 帖（有讨论）；DTC 20 站中 9 站在售（供给拥挤）。
- 站内外：站内 `monthly_search_volume` 环比 −4%，站外 +3.4%，未达 15% 背离线 → 不标背离。
- 结论行：`结论：趋势平稳（5 年 R² 0.31），12 月峰值 index 1.94，站外未起量，备货系数 2.23`。

## 输出契约

- 落盘：`out/<run_id>/trend_series.csv`、`out/<run_id>/seasonality.md`、`out/<run_id>/offsite_signals.md`
- `trend_series.csv` 列：

| 列名 | 说明 |
|---|---|
| `source`（扩展） | google_trends / tiktok / reddit / dtc |
| `query`（扩展） | 词或 hashtag 或 subreddit |
| `date`（扩展） | YYYY-MM（月粒度）或 YYYY-MM-DD（周/日粒度） |
| `interest_value`（扩展） | 0–100（Trends）或原始计数（其他源，另列 `raw_count`） |
| `raw_count`（扩展） | 原始计数：视频数/帖子数/评论数 |
| `trend_slope_pct`（扩展） | %/月，仅月序列有值 |
| `seasonality_index`（扩展） | 该月系数，1.00 为年均 |
| `peak_month`（扩展） | 1–12，同一 query 各行相同 |
| `offsite_score`（扩展） | 0–100，同一 query 各行相同 |
| `evidence_grade` | A/B/C/D |
| `collected_at` | ISO 时间戳（含时区） |

- `seasonality.md` 必含：12 个月系数表（1–12 月 × 每个核心词）、峰值/谷值月、备货系数、`slope_conflict` 标记。
- `offsite_signals.md` 必含：四源逐条明细与链接、每源的采集时间与降级说明。
- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：结论（上升/平稳/下降 + 峰值月）→ 证据（斜率 + 季节系数表 3 行 + 四源计数）→ 动作（例：「采购今天按峰值 index 2.1 把 4 月备货提到 1.15 倍，验收：备货单数量 = 基准月销×2.1×1.15」）。

## 质检清单

- [ ] 首行数据可信度声明：geo、时间窗、四源各自采集时间、降级源列表。
- [ ] 每个核心词有 ≥2 个数据源，单源结论已标 C。
- [ ] `trend_slope_pct` 附 R²，R² <0.50 的已判「无趋势」。
- [ ] 季节性系数用 5 年同月均值算，不是单年数据。
- [ ] 峰值月与 Amazon 站内旺季（若已知）冲突时，已写「冲突说明」。
- [ ] DTC 20 站清单可复现（URL 全列），在售/不在售逐站标注。
- [ ] 站内外背离已检查，`slope_conflict` 已写入 CSV。
- [ ] 无「可能/或许/大概」类表述，方向结论都带数字阈值。

## 反模式

- **只看 12 个月 Trends 就判趋势**：12 个月窗口里一个圣诞峰值就能把斜率拉成正。→ 正确：5 年月序列算斜率，12 个月只算季节形状。
- **用绝对搜索量当趋势**：Trends 是相对指数（0–100），跨词不可比。→ 正确：同一次查询内三词对比，或只用斜率与系数。
- **把 TikTok 一条爆款视频当品类起量**：单条 500 万播放可能只是网红个人流量。→ 正确：看近 30 天视频数环比 ≥1.5 倍 + 至少 3 个不同创作者。
- **季节性用「感觉」**：说「夏天好卖」而不给系数。→ 正确：给 12 个月 index 表，采购按 index×1.15 备货。
- **站外热就判需求强**：TikTok 火但 Amazon 搜索量不动，说明流量被独立站截走。→ 正确：站内外交叉验证，背离时只出「观察」。
