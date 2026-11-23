---
name: competitor-deconstruct
description: 竞品 Listing 解构——卖点矩阵（谁在打什么）、五点信息结构、A+ 模块顺序、变体策略、Coupon/Deal 节奏、库存断货痕迹，输出对标表与「可抄/不可抄」清单。当用户提到「拆竞品」「对手怎么写的」「五点怎么写」「A+ 怎么排」「这个 listing 为什么卖得好」时使用。
layer: 04-competitor
version: 1.0.0
inputs: [category, target_asins, price_history_21d, top10_share, est_monthly_sales]
outputs: [out/<run_id>/竞品解构.md, out/<run_id>/卖点矩阵.csv, out/<run_id>/竞品对标.csv, cmp_claim_saturation, cmp_copyable_list]
upstream: [amz-listing-scrape, market-sizing, market-entry]
downstream: [negative-review-gap, visual-strategy, pricing-ladder, voc-mining]
---

# 竞品 Listing 解构：把对手拆成可抄的零件

## 何时用

1. 准备上新品，要知道首页 5 个对手各自在打哪个卖点、哪个卖点已经打烂了。
2. 自己 listing 转化率低，想知道头部五点结构与 A+ 排列差在哪。
3. 判断对手是否在清库存（Coupon 突然 30%），决定跟不跟价。
4. 找差异化口子：哪个卖点桶还没人打，或打得最浅。
5. 给 `visual-strategy` 提供竞品视觉现状基线。
6. 给 05 层 `compliance-gate` 与文案执行方提供可套用的五点结构模板。

不归这里：差评聚类与改款命题看 `negative-review-gap`；主图公式与视频钩子看 `visual-strategy`；价格带与涨价弹性看 `pricing-ladder`。本 skill 只做「读得出来」的解构，不做评价性打分。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `target_asins` | 前 10 或用户指定的 3–10 个 ASIN | 必需。少于 3 个时结论标「样本不足，仅参考」 |
| `listing_scrape` | 每个 ASIN 的标题/五点/A+ 模块序列/变体/主图与副图 | 必需。A+ 缺失（无品牌备案）时该维度记「无」，不参与饱和度计算 |
| `price_history_21d` | 21 天价格 + coupon 历史（Keepa 类工具） | 缺失时只做单点快照，`coupon_rhythm` 标 `[D]` |
| `est_monthly_sales` | `market-sizing` 的 `est_monthly_sales` | 缺失时用评论增速反推，标 `[C]` |
| `top10_share` | `market-sizing` | 缺失时不影响本 skill，只影响对标权重 |
| `review_velocity` | 近 30 天新增评论数 | 缺失时用「总评论/上架月龄」估，标 `[C]` |

## 执行流程

1. **定对标集**：取 `est_monthly_sales` 前 5 名 + 价格最接近我方目标价的 2 名 + 上架 < 12 个月但评论增速最快的 1 名，共 5–8 个 ASIN。写入 `对标集` 表。

每个 ASIN 必须抓齐的素材（缺一项就把该维度记「无」，不许猜）：

| 素材 | 抓取位置 | 用途 |
|---|---|---|
| 标题全文 | 商品页 H1 | claim 抽取、关键词密度 |
| 五点全文 | Bullet Points 区 | 结构解构、字符数、数字化率 |
| A+ 模块序列 | A+ 区逐屏截图 | 模块顺序与数量 |
| 主图 + 6 张副图 | 图库原图 | 视觉策略基线（给 `visual-strategy`） |
| 变体树 | 变体选择器 | 变体轴与数量 |
| 21 天价格与 coupon | Keepa 类工具 | 促销节奏 |
| 库存状态与跟卖数 | 商品页 Availability 区 | 断货痕迹 |
| 评论总数与近 30 天新增 | 评论区筛选 | 评论增速 |

2. **抽 claim**：对每个 ASIN，从标题、五点、A+ 文案、副图文字里逐句抽「主张句」（含形容词或数字的短句），每条打桶标签。
3. **归 8 桶**：材质 / 结构 / 尺寸 / 耐用 / 易用 / 兼容 / 安全 / 颜值。一桶一条，同桶重复只算 1 次。桶定义见 `references/claim-buckets.md`。
4. **算卖点饱和度**：`sat_bucket = 打该桶的 ASIN 数 / 对标 ASIN 总数`，落 `cmp_claim_saturation`（取最高桶的值）。
5. **解五点结构**：逐条标类型（痛点 / 参数 / 场景 / 背书 / 售后）、字符数、是否含数字、是否含具体场景词。算 `数字化率 = 含数字条数 / 5`。
6. **解 A+ 顺序**：把 A+ 模块映射到 8 类标准模块（品牌故事 / 主视觉 Banner / 对比表 / 使用步骤 / 场景图 / 参数表 / FAQ / 关联购买），记序列与模块数。
7. **解变体策略**：变体数、变体轴（颜色 / 尺寸 / 套装）、是否父子共享评论、是否有非售卖变体虚位。
8. **解 Coupon/Deal 节奏**：从 21 天价格历史算 `coupon_rate` 均值、`deal_days` 天数、`price_volatility = 价格标准差 / 均价`。
9. **查断货痕迹**：记录「Currently unavailable」次数、跟卖（Other Sellers）数、BSR 是否出现 >50% 的断崖后回升。
10. **出对标表**：行 = ASIN，列 = 主力卖点桶 / 五点数 / 数字化率 / A+ 模块数 / 变体数 / coupon / 月销 / 评论增速。
11. **出可抄/不可抄清单**：按「判定口径」逐条判，可抄项写成可执行句（直接能进 `compliance-gate` 过审后的文案稿）。
12. **出竞品对标.csv**：按 `excel-report` 竞品对标 sheet 的固定列输出——`asin, brand, price_usd, review_count, rating, bsr, est_monthly_sales, top10_share, image_style, note`，行按 `est_monthly_sales` 降序；`image_style` 取白底/场景/对比/混合 四值之一。
13. **落盘**：`卖点矩阵.csv` + `竞品对标.csv` + `竞品解构.md`（结论行→矩阵→对标表→可抄清单→动作）。

算例（真实量级）：8 个对标 ASIN，材质桶 7 个打（`sat = 0.88` → 红海）、结构桶 3 个（`0.38` → 可差异化）、安全桶 1 个（`0.13` → 空白）；五点平均 168 字符、数字化率 0.8；A+ 模块数中位 6；coupon 均值 8%；2 个 ASIN 近 30 天出现断货 → 结论：结构桶 + 安全桶双口子，可抄「承重 30 lb 数字 + 防滑底座结构」，不可抄「专利折叠铰链」。

## 判定口径

| 指标 | 阈值 | 判定 |
|---|---|---|
| 卖点饱和度 `sat` | ≥ 0.70 | 红海桶，不主推（只能作为辅助卖点） |
| 卖点饱和度 `sat` | 0.30–0.70 | 可差异化桶，需配证据（数字/测试） |
| 卖点饱和度 `sat` | < 0.30 | 空白桶，优先打，但需验证用户是否在意（查差评/问答） |
| 五点字符数 | 150–220 字符/条 | 合规区间；> 260 移动端被截断 |
| 数字化率 | ≥ 0.8 | 结构合格；< 0.5 说明全是形容词，可直接超越 |
| A+ 模块数 | 5–7 | 标准；< 4 信息不足，> 9 用户滑不到底 |
| A+ 首模块 | 必须是主视觉或对比表 | 品牌故事放首屏 = 浪费首屏 |
| 变体数 | < 3 | 单品策略，风险集中 |
| 变体数 | 3–8 | 健康 |
| 变体数 | > 8 | 铺货型，评论分散，`top_review_count` 被稀释 |
| `coupon_rate` | < 5% | 无效促销，不构成价格威胁 |
| `coupon_rate` | 5%–10% | 常规维护 |
| `coupon_rate` | 15%–20% | 促销期，避开正面比价 |
| `coupon_rate` | > 25% | 清库存信号，30 天内大概率降价或断货 |
| `price_volatility` | > 0.12 | 频繁调价，价格战类目 |
| 断货次数（30 天） | ≥ 2 | 供应不稳，可抢排名窗口 |
| `review_velocity` | > 总评论 × 8%/月 | 高速爬坡，进入窗口正在关闭 |
| 可抄判定 | 三项全满足 | ① 有数字/测试证据 ② 1688 有现成方案 ③ 无专利与品牌词 |
| 不可抄判定 | 命中任一 | 品牌词 / 外观或实用新型专利 / 需认证资质 / 平台专属 A+ 素材 |

## 输出契约

- 落盘：`out/<run_id>/竞品解构.md`、`out/<run_id>/卖点矩阵.csv`。
- `卖点矩阵.csv` 列：字典字段逐字一致 → `sku, category, product, price_usd, top_review_count, top10_share`；扩展列 → `cmp_asin, cmp_claim_bucket, cmp_claim_text, cmp_saturation, cmp_bullet_chars, cmp_digit_ratio, cmp_aplus_modules, cmp_variant_count, cmp_coupon_rate, cmp_deal_days, cmp_price_volatility, cmp_stockout_count, cmp_copyable`。
- `竞品对标.csv` 列（与 `excel-report` 竞品对标 sheet 逐字对齐）：`asin, brand, price_usd, review_count, rating, bsr, est_monthly_sales, top10_share, image_style, note, cmp_claim_saturation, cmp_copyable`。
- 正文五段：**结论行 → 卖点矩阵（8 桶 × 饱和度）→ 对标表 → 可抄/不可抄清单 → 动作**。
- 结论行：`结论：红海桶 {桶名}（sat {值}），空口子 {桶名}，五点结构基准 {字符数} 字符/数字化率 {值}，可抄 {N} 条 [B]`

跨层交接字段：

| 字段 | 消费层 | 用途 |
|---|---|---|
| `cmp_claim_saturation` | `visual-strategy`、`voc-mining` | 决定主图/五点主推哪个桶 |
| `cmp_bullet_chars` / `cmp_digit_ratio` | 文案执行方、`compliance-gate` | 五点写作基准线 |
| `cmp_aplus_modules` | `visual-strategy` | A+ 模块数与顺序基线 |
| `cmp_coupon_rate` / `cmp_stockout_count` | `pricing-ladder` | 判断对手价格战意愿，定锚点安全区 |
| `cmp_copyable` | 05-product、07-system | 合规审查入口：可抄清单进文案前必须过侵权筛查 |

## 质检清单

- [ ] 对标 ASIN 5–8 个，含至少 1 个新品，组成有理由。
- [ ] 每个 claim 只打 1 个桶，无重复计分。
- [ ] 饱和度分母是对标 ASIN 总数，不是 claim 条数。
- [ ] 五点字符数与数字化率逐条可查，不是均值糊过去。
- [ ] A+ 模块用 8 类标准名，未自造模块名。
- [ ] 断货判定有截图或时间戳，不是「感觉断过货」。
- [ ] 数据可信度声明：价格历史若为单点快照已标 `[D]`。
- [ ] 可抄清单每条都写了「抄什么 + 抄到哪个位置（主图/五点第几条/A+ 第几屏）」。

## 反模式

1. **把形容词当卖点**。错误：抄「premium quality」。正确：只抄带数字或结构描述的主张，如「承重 30 lb」「底座宽 4.2 in」。
2. **饱和度按 claim 条数算**。错误：材质桶出现 20 次 / 总 60 条 = 0.33。正确：7 个 ASIN 打 / 8 个 ASIN = 0.88。
3. **A+ 只看有没有**。正确：记模块顺序，首屏放品牌故事直接判「首屏浪费」。
4. **Coupon 只看当日**。正确：看 21 天均值与波动率，识别清库存。
5. **可抄清单写成方向**。错误：「加强结构卖点」。正确：「五点第 2 条写『承重 30 lb，实测 200 次开合无松动』，配一副图承重测试」。
