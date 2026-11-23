# 四源取数手册与季节系数算法

供 `web-trend-scan` 步骤 2–5、6–7 直接执行。每个源都必须记 `collected_at` 与降级原因。

## 1. Google Trends

| 项 | 口径 |
|---|---|
| 地理 | `geo=US`（非美国站同步换 `GB`/`DE`/`JP`/`CA`） |
| 时间窗 | `today 5-y`（月粒度，算斜率）＋ `today 12-m`（周粒度，算季节形状） |
| 类别 | `cat=0`（全部类别）；家居品类可选 `cat=18`（Home & Garden） |
| 搜索类型 | `gprop=` 空（网页搜索）；不看图片/新闻 |
| 词数 | 每查询 ≤5 个词，超了分批，用共同锚词（如 `amazon`）对齐量级 |
| 导出 | CSV：`date`、`interest_value`；周粒度需自行聚成月均值 |

处理规则：
1. 5 年序列中若有 >30% 的月为 0，说明词量太小 → 降级为 C，改用 `offsite_score` 辅助。
2. 周序列转月：同月各周取算术平均。
3. 分批查询时必须含 1 个锚词（量级稳定的通用词），用锚词比例做跨批归一。

## 2. TikTok

| 项 | 口径 |
|---|---|
| 入口 | 话题页（`/tag/<hashtag>`）或 TikTok Creative Center 关键词洞察 |
| 指标 1 | `total_views` 累计播放量（话题页顶部） |
| 指标 2 | 近 30 天新增视频数；无直接入口时用「最新」排序取前 100 条视频发布日分布反推 |
| 指标 3 | 近 30 天 Top 10 视频平均点赞（剔除单条 >500 万播放的极端值后再算） |
| 环比 | 近 30 天视频数 ÷ 前 30 天视频数 |
| 创作者数 | 近 30 天 Top 20 视频的不同作者数，<3 个判「单点爆款」 |

降级：话题页需登录 → 用 Creative Center 公开页，标 B；两者都取不到 → 该源剔除，标 D，并在报告写明「TikTok 源缺失」。

## 3. Reddit

| 项 | 口径 |
|---|---|
| 入口 | `https://www.reddit.com/r/<sub>/search.json?q=<词>&restrict_sr=1&sort=new&t=year` |
| 时间窗 | 近 90 天（算讨论度）＋ 近 12 个月按月（算趋势） |
| 指标 | 帖子数、总评论数、平均赞、Top 5 帖子（标题+链接+赞数） |
| 频控 | 每 2 秒 1 请求，单 sub 上限 500 帖 |
| 去噪 | 剔除 `[WTB]`/`[WTS]`/`for sale`/`coupon` 类交易帖 |

品类 → subreddit 默认映射：

| 品类 | subreddit |
|---|---|
| 厨房小工具 | `Cooking`, `AskCulinary`, `BuyItForLife` |
| 家居收纳 | `HomeImprovement`, `organization`, `declutter` |
| 宠物用品 | `dogs`, `cats`, `DogTraining` |
| 户外露营 | `camping`, `CampingGear`, `Ultralight` |
| 美妆个护 | `SkincareAddiction`, `MakeupAddiction` |
| 母婴 | `Parenting`, `beyondthebump` |
| 3C 配件 | `gadgets`, `BuyItForLife`, `iphone` |

## 4. 独立站（DTC）

| 项 | 口径 |
|---|---|
| 站点数 | 20 个；构成 = 类目 Top 10 品牌站 + 10 个 `site:myshopify.com <词>` 结果 |
| 在售判定 | 站内搜索该词，有 ≥1 个商品详情页即「在售」 |
| 价格带 | 取在售 SKU 价格 min / median / max，币种统一 USD（汇率用全局 FX 同源） |
| 上新速度 | collection 页按 `new` 排序前 20 个商品的 `published_at`，统计近 90 天数量 |
| 评论数 | 商品页 review 组件总数（Judge.me / Yotpo / Loox 均可读总数） |
| 投放 | 公开广告库（Meta Ad Library / Google Ads Transparency）搜品牌名，近 30 天是否在投 |

DTC 供给分档：20 站中在售 ≥8 站 = 供给拥挤（价格战风险）；3–7 站 = 需求已验证且未饱和；<3 站 = 需求未验证（可能是伪需求）。

## 5. 斜率算法（可直接照抄）

```
输入：月序列 interest[1..N]（N=60 或 12），t[i] = i
b = Σ((t_i - t̄)(y_i - ȳ)) / Σ((t_i - t̄)²)
a = ȳ - b·t̄
R² = 1 - SS_res / SS_tot
trend_slope_pct = b / ȳ × 100        # %/月
```

判读：
- `trend_slope_pct > +3` 且 `R² ≥ 0.50` → 上升。
- `|trend_slope_pct| ≤ 3` 或 `R² < 0.50` → 平稳/无趋势。
- `trend_slope_pct < -3` 且 `R² ≥ 0.50` → 下降。

## 6. 季节系数算法

```
monthly_mean[m] = mean(所有年份 m 月的 interest)      # m = 1..12
overall_mean    = mean(全部 interest)
seasonality_index[m] = monthly_mean[m] / overall_mean
peak_month   = argmax(monthly_mean)
trough_month = argmin(monthly_mean)
season_amplitude = max(monthly_mean) / min(monthly_mean)
```

要求：至少 3 年数据；只有 1–2 年时系数标 C，且不得用于备货系数计算。

备货：`峰值月备货量 = 基准月销 × seasonality_index[peak_month] × 1.15`。

## 7. 合成分（offsite_score）

```
tiktok_norm  = minmax(tiktok_30d_views, 参照集 10 品)
reddit_norm  = minmax(reddit_90d_posts, 参照集 10 品)
dtc_norm     = minmax(dtc_90d_new_skus, 参照集 10 品)
offsite_score = 100 × (0.40×tiktok_norm + 0.30×reddit_norm + 0.30×dtc_norm)
```

参照集必须同类目、同价格带（价差 ≤1.5 倍），否则归一化无意义。参照集写进 `offsite_signals.md`。

## 8. 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| Trends 全 0 | 词太小众或被 `cat` 过滤 | 换 `cat=0` 重取；仍 0 → 该源剔除 |
| 季节峰值在 11–12 月 | 圣诞购物季，几乎所有品类都有 | 与类目自身旺季区分，报告写「圣诞拉动，非品类旺季」 |
| TikTok 播放量极高但视频数不涨 | 单条爆款 | 需 ≥3 创作者 + 视频数环比 ≥1.5 才算起量 |
| Reddit 讨论在但 Amazon 无搜索 | 极客小众需求 | 判「有讨论无商业需求」，不进选品池 |
| DTC 20 站全在售 | 品类成熟、门槛低 | 供给拥挤，需差异化或价格带错位 |
