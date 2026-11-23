---
name: market-sizing
description: 类目规模双算——自上而下用 BSR 反推 GMV、自下而上用「搜索量×转化率×均价」算需求侧，两算偏差 >40% 判定口径失败并强制换口径，输出 TAM/SAM/SOM 与置信区间。当用户提到「市场多大」「类目容量」「TAM」「这个类目天花板」「还能不能进」或需要给候选品做规模校验时使用。
layer: 02-market
version: 1.0.0
inputs: [category, bsr_snapshot, monthly_search_volume, price_usd, top10_share, cvr_source, cert_required]
outputs: [out/<run_id>/市场测算.md, out/<run_id>/市场测算.csv, mkt_tam_usd, mkt_sam_usd, mkt_som_usd, mkt_size_confidence]
upstream: [amz-listing-scrape, amz-keyword-harvest]
downstream: [market-trend, market-entry, pricing-ladder, demand-priority]
---

# 市场规模双算：自上而下 × 自下而上

## 何时用

1. 新类目初筛：拿到节点 30 分钟内回答「这个类目一年能做多少钱」，口径要能复算。
2. 候选品已算出贡献利润（05 层），但不确定池子够不够养活一条专线供应链。
3. 老板要 TAM，且不接受拍一个数——需要区间、偏差、置信等级三件套。
4. 两个数据源容量差 2 倍以上（付费工具 vs 前台抓取），需要判定谁的口径错。
5. 进入前定 12 个月 SOM 目标，反推广告预算与首单备货量。
6. 判断是否值得为一个类目开第二条供应链（TAM < 500 万 USD/年时直接否掉）。

不归这里：判「能不能进」看 `market-entry`；把规模拆成 12 个月曲线与旺季看 `market-trend`；单品赚不赚钱看 `profit-model`（本 skill 不算三层利润，只调用其结果做 SANITY 检查）。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `category` | 用户指定的 Amazon US 类目节点 | 必需。只给商品则先用 01 层反查节点；反查不到终止并要 URL |
| `bsr_snapshot` | Best Sellers 前 100 名快照（排名/售价/评论/上架时间） | 必需。同窗口 ≤2 小时；跨窗口重抓 |
| `monthly_search_volume` | 01 层关键词表（Brand Analytics 或付费工具） | 缺失则只做自上而下单算，置信降到 C，禁止出 CI 与 SOM |
| `price_usd` | 前台实付价（coupon/Deal 后） | 必需。取实付，不取 list price |
| `top10_share` | 前 10 listing 销量占比 | 缺失时用「前 10 评论数 / 前 100 评论数」临时替代，标 `[C]` |
| `cvr_source` | 后台实测 CVR 或类目均值 | 缺失时用下方价格带 CVR 表，标 `[C]` |
| `cert_required` | 是否需认证/资质（0/1） | 缺失按 1 处理（保守），SAM 折损 0.6 已计入 |
| `return_rate` | 退货率 | 只用于校验：`return_rate > 0.15` 时 TAM 按 `(1−return_rate)` 折算净规模 |
| `price_band_edges` | 五档价格边界 | 缺失用默认 `0/15/25/45/80/∞` USD |

## 执行流程

1. **锁窗口**：把抓取时间写入 `bsr_snapshot.fetched_at`；时间窗 > 2 小时直接判快照作废，重抓，不进入下一步。
2. **建单品月销**：对 BSR 1–100 查 `references/bsr-sales-table.md`，按 `月销 = k × BSR^(−b)` 取值，两档之间线性插值。不同类目 `k`、`b` 不同，禁止跨类目套用。
3. **自上而下算 GMV**：`gmv_top100 = Σ(月销_i × price_i)`，USD/月。
4. **取覆盖倍数 M**：按 `top10_share` 三档 → `<0.45: 4.0`、`0.45–0.65: 2.5`、`>0.65: 1.6`。集中度越高，Top100 越接近类目全量，M 越小。
5. **自上而下 TAM**：`TAM_TD = gmv_top100 × M × 12`。
6. **选自下而上关键词**：类目首词 + 属性长尾词共 5–15 个，纳入词搜索量合计须 ≥ 首词 × 3。
7. **取自下而上 CVR**：价格带 `<15 → 12%`、`15–25 → 10%`、`25–45 → 8.5%`、`45–80 → 7%`、`>80 → 5.5%`；有后台实测优先实测。
8. **自下而上 TAM**：`TAM_BU = Σ搜索量 × CVR × 均价 × 12`。均价用该价格带加权均价，不用类目算术平均。
9. **算偏差**：`dev = |TAM_TD − TAM_BU| / TAM_BU`，写入 CSV 的 `mkt_dev` 列。
10. **判口径**：按「判定口径」表定级；`dev > 0.40` 时禁止输出单值 TAM。
11. **换口径三分支**（按序试，最多两轮）：a. 关键词集合换成属性长尾词重算 BU；b. CVR 换成同类目后台实测重算 BU；c. 用「Top100 评论数占全类目评论数比例」反推 M 重算 TD。两轮后仍 >0.40，结论写「口径不可用」，置信 D，不出 SOM。
12. **算 SAM**：`SAM = TAM × 价格带匹配率 × 认证折损 × 专利折损`；认证折损 `cert_required=1 → 0.6`；专利折损按有专利主张的头部 listing 销量占比扣减。
13. **算 SOM**：`SOM = SAM × 可获份额`；分散档 0.8%、集中档 0.5%、寡头档 0.25%；`cmp_diff_gap_score ≥ 7` 时 ×1.5，上限 2%。
14. **出区间**：`CI = [min(TD, BU), max(TD, BU)]`，仅 `dev ≤ 0.40` 时输出，并给 ± 百分比。
15. **落盘**：`市场测算.csv`（逐 listing）+ `市场测算.md`（结论行→双算表→口径判定→SOM 与动作）。

算例（可直接照抄格式，数字是真实量级）：类目 `Kitchen Gadgets`，`gmv_top100 = 2,140,000`，`top10_share = 0.38` → `M = 4.0` → `TAM_TD = 102.7M/年`；`Σ搜索量 = 1,860,000/月`，带 CVR `8.5%`，均价 `26.4` → `TAM_BU = 50.1M/年`；`dev = 1.05` → 口径失败 → 换 CVR 实测 `5.2%` → `TAM_BU = 30.6M` → `dev = 2.35` 仍失败 → 结论「口径不可用」。这说明该 BSR 表 `k` 值偏大，必须先换映射表。

异常处理（不中断流程，写入报告「异常」段）：

| 现象 | 处理 |
|---|---|
| Top100 中 >30% 无 BSR（变体父体） | 按子体销量拆分后回填，禁按 0 处理 |
| 单 listing 月销 > 类目第 2 名 3 倍 | 标记「疑似异常刷单」，做敏感性分析：剔除该 listing 重算 `dev` |
| 关键词表含品牌词占比 >20% | 剔除品牌词重算 `TAM_BU`，否则需求侧虚高 |
| 类目存在 Amazon 自营占比 >25% | TAM 照算，但 SOM 份额打 0.6 折并在结论标注 |

## 判定口径

| 指标 | 阈值 | 含义 |
|---|---|---|
| 双算偏差 `dev` | ≤ 0.15 | 可信，TAM 取两算中位数，置信 A/B |
| 双算偏差 `dev` | 0.15–0.40 | 可用，必须并列两算值，置信降 B/C |
| 双算偏差 `dev` | > 0.40 | 口径失败，禁单值，强制换口径 |
| 快照时间窗 | > 2 小时 | 快照作废 |
| 关键词覆盖 | 纳入词合计 < 首词 × 3 | 关键词集合不足，`TAM_BU` 系统性偏低 |
| 均价变异系数 | > 0.6 | 价格带不成立，先切子类目再算 |
| TAM | < 500 万 USD/年 | 池子过小，直接判不做 |
| TAM | 500 万–3000 万 USD/年 | 中小卖家适配区 |
| TAM | > 3 亿 USD/年 | 巨头战场，仅 `top10_share < 0.45` 可考虑 |
| SOM | < 15 万 USD/年 | 撑不起专线，需捆绑多品或放弃 |
| `return_rate` | > 0.15 | TAM 按 `(1−return_rate)` 折净规模 |
| 净规模/首单投入 | < 3 倍 | 回本周期过长，降级为「观察」 |

参数速查（改参数必须同步改本表，禁止口头约定）：

| 参数 | 取值 | 适用 | 来源口径 |
|---|---|---|---|
| `M` 覆盖倍数 | 4.0 / 2.5 / 1.6 | 按 `top10_share` 三档 | 本 skill 实测回归，`references/bsr-sales-table.md` 附录 |
| `CVR` 价格带表 | 12% / 10% / 8.5% / 7% / 5.5% | `<15 / 15–25 / 25–45 / 45–80 / >80` | Amazon US 类目均值，标 `[C]` |
| 认证折损 | 0.6 | `cert_required = 1` | 认证品类过审率经验值，`[C]` |
| SOM 份额 | 0.8% / 0.5% / 0.25% | 分散 / 集中 / 寡头 | 新品 12 个月份额中位数，`[C]` |
| 差异化加成 | ×1.5，上限 2% | `cmp_diff_gap_score ≥ 7` | 与 04 层 `negative-review-gap` 联用 |

## 输出契约

- 落盘：`out/<run_id>/市场测算.md`、`out/<run_id>/市场测算.csv`。
- CSV 列：`engine/score.py` 字典字段逐字一致 → `sku, category, product, price_usd, monthly_search_volume, top10_share`；扩展列 → `bsr, est_monthly_sales, mkt_tam_td_usd, mkt_tam_bu_usd, mkt_dev, mkt_tam_usd, mkt_sam_usd, mkt_som_usd, mkt_ci_low, mkt_ci_high, mkt_size_confidence`。
- 正文四段固定顺序：**结论行 → 双算对照表 → 口径判定 → SOM 与动作 → 数据可信度**。
- 结论行：`结论：TAM {值} USD/年（区间 {低}–{高}，dev {值}），口径 {通过/失败}，SOM 12 个月 {值} USD [B]`

跨层交接字段（消费方按此取数，不得自行改算）：

| 字段 | 消费层 | 用途 |
|---|---|---|
| `mkt_tam_usd` / `mkt_ci_low` / `mkt_ci_high` | 03-demand | 规模校验，TAM 不足则需求分封顶 |
| `mkt_size_confidence` | 07-system | D 级占比统计与报告分级 |
| `mkt_som_usd` | 05-product、06-delivery | 反推备货量与广告预算上限 |
| `est_monthly_sales` | 04-competitor、06-delivery | 竞品销量占比、价格带阶梯销量列；列名与 `excel-report` 竞品对标 sheet 一致 |
| `top10_share` | 02-market（`market-entry`）、engine | 垄断度分档唯一来源，本 skill 只测不算分 |

## 质检清单

- [ ] `bsr_snapshot.fetched_at` 已记录且 ≤2 小时。
- [ ] 100 个 listing 月销全有值，插值处标了所用档位。
- [ ] `mkt_dev` 已落 CSV，判定与阈值表一致。
- [ ] `dev > 0.40` 时报告内无任何单值 TAM，且列出试过的换口径分支。
- [ ] SAM 三个折损系数都有出处，非口径外自创。
- [ ] 结论行与「输出契约」格式逐字一致。
- [ ] 数据可信度声明：逐数字标 A/B/C/D，统计 D 级占比；D 级 >30% 时结论只写「观察」。
- [ ] 至少一条今天能做的动作（谁 / 做什么 / 多久 / 验收标准）。

## 反模式

1. **只算一边就叫 TAM**。错误：`TAM = Top100 月销之和 × 12`。正确：双算 + `dev` 进表 + 超阈值换口径。
2. **用 list price 算 GMV**。错误：抓 $39.99 划线价，实付 $23.99。正确：取 coupon 后实付价。
3. **覆盖倍数拍脑袋**。错误：所有类目都 ×5。正确：按 `top10_share` 取 4.0 / 2.5 / 1.6。
4. **SOM 写「抢占 5% 市场」**。正确：分散 0.8% / 集中 0.5% / 寡头 0.25%，有差异化命题才 ×1.5。
5. **跨月混算**。错误：Top100 抓于 11 月，搜索量取 3 月均值。正确：同窗口，或先用 `market-trend` 季节系数归一到同月。
