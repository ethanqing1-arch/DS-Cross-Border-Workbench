# 工具映射与降级链（纯免费版）

五步流水线每一步调什么、拿不到怎么办。**前面能通就不要往后试。**
抓取能力的实测边界见 `references/free-stack-verified.md`，不要重新试已经证否的路。

## 三条通道

| 通道 | 形态 | 怎么用 | 成本 | 能力边界 |
|---|---|---|---|---|
| **本机抓取** | Python + curl | `python3 scripts/fetch_amazon.py ...` | 0 | 搜索页全字段、商品页价格/评分/评论数/BSR/五点 |
| **lingxiao** | HTTP MCP | `mcp__lingxiao__<tool>` | 0（20 次/IP/天） | 只许调 5 个：判本质、需求报告、利润测算 |
| **官方免费源** | 网页/后台 | 人工或 Playwright | 0 | 商机探测器、ABA、Google Trends |

**不要用** `scrape_webpage` / `read_url` 抓 Amazon——实测 503。**不要**指望免费拿评论原文——实测跳登录。

## 抓取器速查

```bash
cd ~/.ds-bot/skills/market-research/scripts

# 搜索页：ASIN / 标题 / 价格 / 评分 / 评论数 / 是否广告
python3 fetch_amazon.py search "pet slow feeder" --limit 20 --csv

# 商品页：上面那些 + BSR + 五点描述
python3 fetch_amazon.py product B0C5HSCS8J
```

返回里出现 `"degraded": true` 就是被拦了 → 隔 10 秒重试一次，还不行就写「缺口」，不许用别的数凑。

## 第 1 步 判品类驱动本质

| 优先级 | 调用 | 返回 |
|---|---|---|
| 1 | `mcp__lingxiao__selection_category_nature`（参数 `text`，传一段中文品类描述） | 需求驱动 / 身份情绪驱动 |
| 2 | 人工按 SKILL.md 那张表判 | 结论标 `[人工判定]` |

**实测坑（2026-11-22）**：细分品类会返回 `"nature": "mixed", "label": "混合/待判", "warning": "信号不足"`。「慢食狗碗」就是这样——它的关键词库里没有这个词组。`mixed` **不是结论**，必须转人工判，不许写成「混合驱动」当结论用。

## 第 2 步 需求

| 优先级 | 调用 | 拿什么 |
|---|---|---|
| 1 | `mcp__lingxiao__market_research_options` → `market_research_report`（`category`+`country`） | 类目容量、增长 |
| 2 | **Amazon 商机探测器**（卖家后台，免费） | 搜索量区间、点击集中度、新品占比——最准 |
| 3 | ABA 免费榜单 / Google Trends | 词级趋势、季节性 |
| 4 | `fetch_amazon.py search "<词>" --limit 48` → 数卡片、看 `total_results_text` | 在售规模 |

`market_research_report` 返回 400 是"没有这个组合的数据"，**不是"没需求"**。这是本步最容易犯的错。

**实测坑（2026-11-22）**：`market_research_report` 的数据源是 **Google 搜索 + 关键词库**，不是 Amazon。查「宠物 × US」返回的 `topOpportunities` 是 `shih tzu puppies for sale`、`chow dogs for sale` —— 都是**买狗**的词，对卖狗碗毫无意义。数据快照日期也可能滞后 3–4 个月。

所以本步顺序要反过来：
1. **Amazon 商机探测器**（官方、免费、Amazon 口径）← 主
2. 自己抓的搜索结果数 + 评论数 ← 佐证
3. lingxiao 报告 ← 只当"这个国家有没有这个品类的大盘"的背景音，**不用于判断具体产品需求**

## 第 3 步 竞争

| 要回答 | 怎么做 |
|---|---|
| 有多少家在卖 | `fetch_amazon.py search "<词>" --limit 48` → 返回 `48`，配合页面上的 `over N results` |
| 价格带分布 | 同上 CSV 的 `price` 列，做分位数（P25/P50/P75），**不看均值** |
| 品牌集中度 | 标题里的品牌词聚合，前 3 品牌占比 < 45% 才算有缝 |
| 头部评论门槛 | `reviews` 列排序，看前 5 名是多少（> 5000 且自有品牌 → 红线） |
| 广告位密度 | `sponsored` 列，首页广告占比 > 30% 说明要靠付费抢 |
| 竞品靠哪些词吃流量 | 商品页 `bullet`/标题反推 + Google Trends 对照；精确流量结构免费拿不到，写「缺口」 |

抓完 48 个 → 排序 → **只对前 5 名跑 `product`**。这一步是省时间的核心。

## 第 4 步 利润

| 优先级 | 调用 | 可用性 |
|---|---|---|
| 1 | **手算**：`90-templates/pricing-model.csv` + `10-market/fx.md` | ✅ **唯一可信口径** |
| 2 | `mcp__lingxiao__profit_estimate` | ⚠️ 见下 |
| 3 | `mcp__lingxiao__supply_cost_estimate` | ⚠️ 未验证 |

**实测坑（2026-11-22，重要）**：`profit_estimate` 的 `category` 参数会**静默错配**——传 `"宠物"` 和传 `"pet"` 都映射成 `bags / 女包/小包`，费率档位用错；`countries` 传 `["US","UK","DE"]` 返回 `countryCount: 0`、`rows: []`，根本没算。而且它明说"费率档位、物流分档与退货预留的口径明细只在登录版给出，这里只给测算结果"。

**结论：匿名档的 `profit_estimate` 不可用于决策**。看到 `rows: []` 或 `categoryLabel` 跟你的品类对不上，立刻停，转手算。

手算模板（$9.86 售价实例，口径见 README）：

```
售价 ¥69.0
− 佣金 15%      ¥10.4
− FBA 履约      ¥25.2   ← 200g 小件，占售价 36%，低价品的真正杀手
− 货值+头程     ¥11.0
− 广告 15%      ¥10.4
− 退货 3%       ¥2.1
− 支付汇损 1.2% ¥0.8
= 利润 ¥9.22 → 净利率 13.4% → 低于 25% 测款线
```

## 第 5 步 评论证据

免费能拿：

| 字段 | 来源 |
|---|---|
| 评分 + 评论总数 | `fetch_amazon.py product <ASIN>` |
| 五点描述 | 同上 `bullets` |
| 星级分布直方图 | ❌ 免费拿不到 |
| 差评原文 | ❌ 免费拿不到（跳登录） |

两种处理，二选一，**在汇报里写明用了哪种**：

- **A（推荐）**：用 DS-Bot 的 cookie 导入，登录一次 Amazon，Playwright 带 cookie 读 `/product-reviews/<ASIN>?filterByStar=critical`。拿到原文后按「购买顾虑」分类。
- **B（降级）**：只用评分分布缺失下的替代信号——评分低于 4.5、评论数少但评分低、五点里主动强调某个弱点（说明竞品在这栽过）。汇报里必须写「评论原文缺口，痛点判断为间接推断」。

## 单候选标准动作（约 5–8 分钟）

```
1  fetch_amazon.py search "<主词>" --limit 48 --csv     → 候选池 + 价格带 + 评论门槛
2  排序，取前 5
3  fetch_amazon.py product <ASIN>  ×5                    → 价格/BSR/评分/五点
4  （可选）lingxiao profit_estimate                      → 利润区间
5  （可选 A 方案）评论原文
6  按 selection-score.md 打分 → 写 10-market/candidates/<候选ID>.md
```

结果落 `10-market/competitors/<ASIN>.md`，下次直接读文件不重抓。

## 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `degraded: true` + `blocked_by_amazon` | 抓太密被风控 | 停 10 分钟；每 10 个间隔 3–5 秒 |
| `http_503` | 同上 | 同上；换 UA 池里的另一个 |
| 价格是 `CNY xx` | 缺 USD cookie | 必须带 `i18n-prefs=USD`，脚本已内置，自写的一定要加 |
| `bullets: []` | 该 listing 没有 `#feature-bullets` 区块 | 正常现象，不是 bug，写「五点缺口」 |
| 评论页跳 signin | 未登录 | 走 A 方案导入 cookie，或按 B 方案降级 |
| lingxiao 额度用尽 | 20 次/IP/天 | 换天；或全走抓取器 |
| 汇率文件过期 | 超过 7 天 | 先让 Margin 更新 `10-market/fx.md` |
