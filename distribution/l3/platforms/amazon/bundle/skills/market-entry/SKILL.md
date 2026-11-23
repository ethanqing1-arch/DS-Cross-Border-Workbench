---
name: market-entry
description: 可进入性判定——垄断度、Review 壁垒、价格带空位、广告成本倒推、Amazon's Choice 与品牌旗舰店占比五路证据合成进入难度评级（0–100），并给出价格错位/功能错位/场景错位三种进入姿势。当用户提到「这个类目还能进吗」「评论太多了打不过」「进去要烧多少钱广告」「有没有空位」「红海还是蓝海」时使用。
layer: 02-market
version: 1.0.0
inputs: [category, top10_share, top_review_count, listing_age_months, cpc_usd, cvr_source, contribution_profit_usd, price_usd]
outputs: [out/<run_id>/进入难度.md, out/<run_id>/进入难度.csv, mkt_entry_score, mkt_entry_grade, mkt_entry_posture]
upstream: [amz-listing-scrape, amz-keyword-harvest, market-sizing, profit-model]
downstream: [pricing-ladder, negative-review-gap, visual-strategy, demand-priority]
---

# 可进入性：难度评级 + 进入姿势

## 何时用

1. 候选品需求与利润都过了，但首页全是万评老链接，要量化「到底打不打得动」。
2. 老板问「进这个类目要准备多少广告费」，需要 CPC×转化倒推单均成本。
3. 判断某个价格带是不是真空位（需求有、供给少）。
4. 同一类目两个细分，用进入难度分做取舍。
5. 决定进入姿势：降价打、改功能打、还是换场景打。
6. 给 05 层一个硬门槛：难度分 > 75 时不再投入开模费。

不归这里：算类目总量看 `market-sizing`；判季节与备货看 `market-trend`；把差评转成改款方案看 `negative-review-gap`；定价阶梯与涨价弹性看 `pricing-ladder`。本 skill **不改写**第 4.2 节四维权重，难度分是独立指标，只作为进入决策的守门项。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `top10_share` | `market-sizing` 实测或 01 层 | 必需。缺失时用「前 10 评论/前 100 评论」替代，标 `[C]` |
| `top_review_count` | 前台抓取 | 必需 |
| `min_page_review` | 首页 48 个自然位中最低评论数（不含广告位） | 缺失时取 `top_review_count × 0.15` 估，标 `[D]` |
| `listing_age_months` | 前 100 listing 上架月龄 | 缺失则新品占比记为 `[D]`，难度分置信降一档 |
| `cpc_usd` | 广告后台实测或第三方广告工具 | 缺失时取类目均值 `$0.85`，标 `[C]`，并在结论写「广告成本为估算」 |
| `cvr_source` | 后台实测 CVR | 缺失用价格带表（见 `market-sizing`），标 `[C]` |
| `contribution_profit_usd` | `profit-model` 输出 | 必需。没有它无法算广告可承受度，终止 |
| `ac_share` / `brand_store_share` | 首页 48 自然位中带 Amazon's Choice 标 / 品牌旗舰店的比例 | 缺失则这两项按 0.3 中性值处理并标注 |

## 执行流程

1. **抓首页 48 个自然位**：排除 SP/SB 广告位（带 Sponsored 标），记录每个位置的评论数、价格、上架月龄、是否有 AC 标、是否品牌旗舰店。
2. **算 `top10_share`**：前 10 listing 销量占比（销量取 `market-sizing` 的 `est_monthly_sales`），落 `top10_share` 字段。
3. **算 Review 壁垒**：取 48 个自然位中**最低**评论数 = `min_page_review`；同时记录第 24 位（首页下半段分界）评论数作为参考。
4. **算新品占比**：`new_share = 上架 < 12 个月的 listing 数 / 100`。
5. **算价格带空位**：把 100 个 listing 按五档装桶（`0/15/25/45/80/∞` USD），逐档算 `需求占比 = 档内销量 / 总销量`、`供给占比 = 档内 listing 数 / 100`，`gap = 需求占比 / 供给占比`。
6. **算单均广告成本**：`CPA = cpc_usd / cvr`；`ad_burden = CPA / contribution_profit_usd`（广告费吃掉贡献利润的比例）。
7. **算 AC 与品牌占比**：`ac_share = AC 数 / 48`；`brand_store_share = 有品牌旗舰店的 listing 数 / 48`。
8. **五路归一**（每项 0–100，越高越难）：
   - 垄断分 `S1 = clip((top10_share − 0.25) / 0.55 × 100, 0, 100)`
   - 评论分 `S2 = clip(log10(1+min_page_review) / log10(3001) × 100, 0, 100)`
   - 广告分 `S3 = clip(ad_burden / 0.8 × 100, 0, 100)`
   - 空位分 `S4 = clip((1.5 − gap_max) / 1.0 × 100, 0, 100)`
   - 板结分 `S5 = clip((20 − new_share×100) / 20 × 100, 0, 100)`
9. **合成难度分**：`entry_score = 0.25×S1 + 0.25×S2 + 0.20×S3 + 0.15×S4 + 0.15×S5`（与四维权重无关，勿混用）。
10. **定级**：按「判定口径」四档；`>75` 直接判「不进」，不论总分多少。
11. **选进入姿势**（按顺序判，命中即停）：
    - 功能错位：`cmp_diff_gap_score ≥ 7`（04 层 `negative-review-gap` 已跑则直读；未跑按中性 6 分，不据空值放行）→ 主打改款点。
    - 价格错位：`目标档中位价 × 0.8` 下仍满足贡献利润率 ≥ 8% → 低价切入；或中位价 × 1.25 且有功能/材质背书 → 高价切入。
    - 场景错位：场景词搜索量占比 ≥ 15% 且 Top10 无 listing 主图/A+ 主打该场景 → 场景切入。
    - 三条都不中：结论「无异位空间」，降级为观察。
12. **落盘**：`进入难度.csv`（逐 listing 48 行）+ `进入难度.md`（结论行→五路证据表→姿势→动作）。

算例（真实量级）：`top10_share = 0.52`、`min_page_review = 180`、`CPA = 0.85/0.085 = 10.0`、`contribution_profit = 12.4` → `ad_burden = 0.81`、`gap_max = 0.92`、`new_share = 0.14` → `S1 = 49`、`S2 = 65`、`S3 = 100`、`S4 = 58`、`S5 = 30` → `entry_score = 61.2` → 「难」；`ad_burden > 0.8` 触发广告红线 → 姿势只能是功能错位，且必须先压 CPC 到 `$0.62` 以下才开测。

## 判定口径

| 指标 | 阈值 | 判定 |
|---|---|---|
| `top10_share` | < 0.45 | 分散，有冷启动窗口 |
| `top10_share` | 0.45–0.65 | 集中，需差异化或价格错位 |
| `top10_share` | > 0.65 | 寡头，无供应链优势不进 |
| `min_page_review` | < 50 | 评论壁垒低，可直接打 |
| `min_page_review` | 50–300 | 中，需 3 个月评论爬坡 |
| `min_page_review` | 300–1,000 | 高，需差异化 + 广告预算 ≥ $6,000/月 |
| `min_page_review` | > 1,000 | 极高，无改款不进 |
| 新品占比 | > 20% | 有窗口 |
| 新品占比 | 10%–20% | 需差异化 |
| 新品占比 | < 10% | 板结，不进 |
| `ad_burden` | ≤ 0.35 | 广告可承受 |
| `ad_burden` | 0.35–0.50 | 需控制 `ad_share` ≤ 0.25 |
| `ad_burden` | > 0.50 | 广告红线，未压 CPC 前不得开测 |
| 价格带 `gap` | ≥ 1.5 且档内 listing ≥ 5 | 真空位，优先切入 |
| 价格带 `gap` | 0.8–1.5 | 均衡区 |
| 价格带 `gap` | < 0.8 | 供给过剩，避开 |
| `ac_share` | > 0.25 | 平台背书集中，自然位被挤压 |
| `brand_store_share` | > 0.40 | 品牌化类目，白牌难做 |
| `entry_score` | ≤ 30 | 易 |
| `entry_score` | 31–55 | 中 |
| `entry_score` | 56–75 | 难 |
| `entry_score` | > 75 | 极难，不进 |

## 输出契约

- 落盘：`out/<run_id>/进入难度.md`、`out/<run_id>/进入难度.csv`。
- CSV 列：字典字段逐字一致 → `sku, category, product, price_usd, competitor_count, top_review_count, top10_share, ad_share`；扩展列 → `mkt_min_page_review, mkt_new_share, mkt_gap_max, mkt_gap_band, mkt_cpc_usd, mkt_cpa_usd, mkt_ad_burden, mkt_ac_share, mkt_brand_store_share, mkt_entry_score, mkt_entry_grade, mkt_entry_posture`。
- 正文五段：**结论行 → 五路证据表 → 难度分解（S1–S5）→ 进入姿势 → 动作**。
- 结论行：`结论：进入难度 {分}/100（{档}），姿势 {价格错位/功能错位/场景错位/无}，首月广告预算上限 {USD} [B]`

跨层交接字段：

| 字段 | 消费层 | 用途 |
|---|---|---|
| `mkt_entry_score` / `mkt_entry_grade` | `demand-priority`、`decision-control` | 难度 >75 时需求分与差异化投入直接封顶 |
| `mkt_cpa_usd` / `mkt_ad_burden` | `profit-model` | 校验 `ad_share` 假设是否成立（`ad_share ≥ ad_burden × 0.5` 则假设不成立） |
| `mkt_gap_band` | `pricing-ladder` | 定价锚点候选档，优先级高于纯销量档 |
| `mkt_entry_posture` | `visual-strategy`、`competitor-deconstruct` | 决定视觉与文案主打方向 |
| `mkt_min_page_review` | `visual-strategy` | 首图/副图需要多强的说服力（评论少则靠图补） |

## 质检清单

- [ ] 48 个位置已排除广告位，只统计自然位。
- [ ] `min_page_review` 取的是最低值，不是首页最高值。
- [ ] `top10_share` 与 `market-sizing` 用的是同一份销量估计，无二次估算。
- [ ] `ad_burden` 用的是贡献利润，不是毛利。
- [ ] 五路分项 `S1`–`S5` 全部列出，未只给总分。
- [ ] 进入姿势只有一条，且给了触发它的那个数字。
- [ ] 数据可信度声明：CPC/CVR 若为估算已标 `[C]`，D 级 >30% 时结论只写「观察」。
- [ ] 至少一条今天能做的动作（例：今天起跑 3 组手动精准词测 CPC，预算 $30/天，7 天验收 CPC ≤ $0.62）。

## 反模式

1. **用最高评论数当壁垒**。错误：`top_review_count = 12,000` 就说打不过。正确：看首页自然位**最低**评论数，那才是你能挤进去的位置。
2. **垄断度自己再算一遍**。正确：直接用 `market-sizing` 的 `top10_share`，两处不一致时以 CSV 为准。
3. **广告成本用「行业平均 ACOS」**。错误：拍 25% ACOS。正确：`CPA = CPC / CVR`，再除贡献利润得 `ad_burden`。
4. **难度分与四维分混算**。错误：把 `entry_score` 乘进总分。正确：两者独立，难度分只做守门（>75 不进）。
5. **三种姿势全给**。错误：报告里写「可以降价也可以改功能也可以换场景」。正确：按顺序判，命中即停，只留一条。
