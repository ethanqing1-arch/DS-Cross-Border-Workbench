# 详情页模块 → 字段映射与解析口径

页面结构会变，选择器只作定位线索；真正的口径是「取哪块文本 + 怎么清洗」。所有解析必须带原始文本落 `raw/`，便于回溯。

## 1. 模块映射表

| 字段 | 页面位置 | 定位线索 | 解析规则 | 失败表现 |
|---|---|---|---|---|
| `product` | 标题 | 商品标题主标题（`#title` 区块内 `span`） | 去首尾空格，保留原文大小写与符号 | 变体页显示「Currently unavailable」→ 记空 |
| 五点 | 五点区 | `About this item` 列表 | 取前 5 条，按 `•`/换行切；不足 5 条按实际条数 | A+ 页面可能无五点 → 记 `bullets_missing=1` |
| `price_usd` | 购买框 | 购买框内价格（非划线价） | 取精确子体的单值报价，区间价原样记 `offer_price_range` | 无 BuyBox 标 `buybox_missing`，最低其他报价单列，不进入同规格主流带 |
| `list_price_usd` | 购买框 | 价格旁删除线文本 | 去 `$`、`List Price:` 前缀 | 无划线价 → 空 |
| `coupon_pct` | 购买框 | `Save x%` / `Apply $x coupon` | `x%`→x/100；`$x`→x/price_usd | 无 → 0 |
| `variation_count` | 变体选择器 | `Color:`/`Size:` 下拉或色块 | 子体条目数，父子体去重；同一子体多属性只计 1 | 无变体选择器 → 1 |
| `bsr_main_rank` | Product information | `Best Sellers Rank` 第 1 行主类目 | 正则取 `#([\d,]+) in`，去逗号 | 类目表折叠 → 展开 `Product information` 再抓 |
| `bsr_sub_rank` | Product information | `Best Sellers Rank` 第 2 行 | 同上，取第 2 个 `#n in <子类目>` | 只有 1 行 → 空 |
| `rated` | 评分区 | 星级旁 `x ratings` | 去 `ratings`/`,`；`(1,234)` → 1234 | 新品 0 评论 → 0 |
| `rating_avg` | 评分区 | 星级数值 | 取 `4.3 out of 5` 的 4.3 | 无评分 → 空 |
| `rating_dist_*` | 评论直方图 | `5 star` 行百分比 | 百分比 ÷100；合计偏差 >2% 标不可用 | 直方图懒加载 → 滚到评论区再抓 |
| `seller_count` | 其他卖家 | `Other Sellers on Amazon` / `New (N) from` | `New (12) from` → 12+1；列表模式数条目+1 | 区块缺失 → 1，`seller_source=buybox_only` |
| `fba_seller_count` | 其他卖家 | 每条 `Fulfilled by Amazon` | 计数 | 不可见 → 空 |
| `listed_since` | Product information | `Date First Available` | `January 5, 2023` → `2023-01` | 缺失 → 空，不推算 |

## 2. 变体抓取顺序

1. 打开父体页，读选择器全部维度名（如 `Color`、`Size`）。
2. 逐子体点击，等价格区刷新（以价格文本变化为信号，最多 5s），读 `asin`（URL `dp/<asin>` 或 `currentAsin` 字段）。
3. 每子体至少记：`child_asin`、属性值、`price_usd`、`in_stock`。
4. 只对价格中位数那个子体抓五点与 BSR（避免 N 倍请求），其余子体只记价格。
5. 子体数 >15 时，只抓价格最低/中位/最高 3 个子体，其余标记 `sampled=1`。

## 3. 失败矩阵

| 现象 | 判定 | 动作 |
|---|---|---|
| 出现 `Enter the characters you see below` | 验证码 | 该 IP 停 15 分钟，换 IP 重试；连续 3 IP → 本轮封版 |
| 页面 200 但无购买框 | 无 BuyBox 或被跟卖 | 取最低 `Other Sellers` 价，标 `buybox_missing=1` |
| 价格区显示 `Currently unavailable` | 断货 | `price_usd` 空，`scrape_status=partial` |
| BSR 表折叠 | 懒加载 | 展开 `Product information`，等待 2s 重抓 |
| 评论区直方图空 | 懒加载或 0 评论 | 滚到评论区等待 3s；仍空则 `rating_dist_*` 空 |
| 五点被 A+ 替代 | 品牌 A+ 页面 | `bullets_missing=1`，五点空，不解析图片文字 |

## 4. 字段质量分级

| 缺失率 | 处理 |
|---|---|
| 0–5% | 正常，字段可用，标 B |
| 5–20% | 可用但报告标注「该列有缺失，均值按有效行算」 |
| >20% | 整列降级 C，不得单独作为结论依据；若为关键列（`price_usd`/`bsr_main_rank`）→ 整轮重抓 |

## 5. 采集频率建议

| 用途 | 频率 | 说明 |
|---|---|---|
| 选品初筛 | 一次性 | 同一 `run_id` 内不重复抓 |
| 价格监控 | 每日 1 次，固定 ET 10:00 | 只抓 `price_usd`、`seller_count`、`coupon_pct` |
| BSR 趋势 | 每周 1 次，周一 ET 10:00 | 只抓 `bsr_main_rank`、`bsr_sub_rank` |
| 变体变化 | 每周 1 次 | 只抓 `variation_count` 与子体价格 |

同一 ASIN 两次抓取间隔 <6 小时的数据，不得用于「变化」结论（抖动大于真实变化）。
