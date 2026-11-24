# 免费栈实测记录（2026-11-22，macOS，Asia/Shanghai）

这份文件是**证据**，不是教程。Scout 遇到"能不能抓到"的问题，先看这里，不要重新试。

## 一、四路抓取对比（同一目标：Amazon US 搜索页 `?k=pet+slow+feeder`）

| 路径 | HTTP | 耗时 | ASIN | 价格 | 评分 | 评论数 | 判定 |
|---|---|---|---|---|---|---|---|
| 内置网页抓取（scrape_webpage） | **503** | — | — | — | — | — | ❌ 指纹被拦 |
| 内置 read_url | **503** | — | — | — | — | — | ❌ 同上 |
| curl + 真实 UA + USD cookie | **200** | 2.5s | ✅ 48/48 | ✅ | ✅ | ✅ | ✅ **主力** |
| Playwright + 本机 Chrome | **200** | 4.0s | ✅ 48 | ✅ | ✅ | ✅ | ✅ 兜底（需交互时用） |

结论：**内置抓取器抓不了 Amazon，curl 反而能抓**。别用 `scrape_webpage` / `read_url` 去碰 Amazon，直接走脚本。

## 二、商品页字段可得性（ASIN `B0C5HSCS8J`）

| 字段 | 免费能拿 | 备注 |
|---|---|---|
| 标题 | ✅ | |
| 价格 | ✅ `$7.64` | **必须带 `i18n-prefs=USD` cookie** |
| 评分 | ✅ `4.6` | |
| 评论总数 | ✅ `10,794` | |
| BSR | ✅ `#1,468 in Pet Supplies` | 正则去重后取第一条 |
| 五点描述 | ✅ 6 条 | 只在 `#feature-bullets` 区块内，`li > span.a-list-item` |
| 星级分布直方图 | ❌ | 未登录被隐藏 |
| "Customers say" AI 摘要 | ❌ | 未登录被隐藏 |
| **评论原文 / 差评筛选** | ❌ | **跳登录页，两路都拿不到** |

## 三、币种陷阱（这个是硬坑）

中国 IP 抓 amazon.com，默认返回 **CNY 折算价**：

```
不带 cookie:  CNY 51.00    ← 含税折算，和真实美区售价差 30%+
带 cookie:    $7.64        ← i18n-prefs=USD 之后的真实美区价
```

`fetch_amazon.py` 已内置 `cookie: i18n-prefs=USD; lc-main=en_US`。任何自写抓取都要带，否则价格带全错。

## 四、评论原文的唯一免费解法

评论页 `/product-reviews/<ASIN>` 一律跳 `/ap/signin`。三条路：

1. **DS-Bot 原生 cookie 导入**（推荐）——DS-Bot 自带 `cookie-import`，你在本机 Chrome 登录一次 Amazon，把 cookie 导进 Playwright context，之后评论页可正常读。用的是你自己的账号，不涉及第三方。
2. 在未登录的商品页分析中，将评论原文、星级分布和 AI 摘要记为缺口。评论总数和五点描述作为各自的证据记录。
3. 只看商品页顶部偶尔露出的 2–3 条评论 —— 量太少，不可作为分类依据。

没有第 4 条。任何声称"免费无登录拿全站评论"的库，实测都是过期或要付费 key。

## 五、复现命令

```bash
cd ~/.ds-bot/skills/market-research/scripts

# 搜索页 → CSV（ASIN/标题/价格/评分/评论数/是否广告）
python3 fetch_amazon.py search "pet slow feeder" --limit 20 --csv

# 商品页 → JSON（含 BSR、五点、上架时间、卖家和发货方）
python3 fetch_amazon.py product B0C5HSCS8J

# 商品页批量 → 打分输入 CSV 和缺失列说明
python3 fetch_amazon.py product --asin-file asins.txt --output amazon-candidates.csv
```

搜索失败时的返回示例

```json
{"error": "blocked_by_amazon", "degraded": true, "rows": []}
{"error": "http_503", "degraded": true, "rows": []}
```

看到 `degraded` 就写「缺口」，不许拿别的字段凑。

批量输入支持每行一个 ASIN，也支持带 `asin` 表头的 CSV。批量输出默认写入
`amazon-candidates.csv`，同目录的 `<output>.README.md` 列出各 ASIN 的待补字段。
打分脚本读取其工作区的 `data/candidates.csv`。导入前请确认目标文件，并将售价和补录成本统一币种。

## 六、速率与礼貌

- 历史实测单次 2–5 秒。间隔低于 1 秒时，连续约 20–30 次后开始出现 503。
- 商品页批量每次最多 20 个 ASIN，串行抓取，两个商品之间随机等待 2–4 秒。
- 每页最多重试两次，保留递增退避和抖动，每次重试至少等待 2 秒。

## 七、Playwright 的定位（别滥用）

它比 curl 慢一倍，但能做 curl 做不到的三件事：

1. 需要点击/翻页/滚动才出现的内容
2. 需要真实浏览器指纹才能过的页面
3. 带 cookie 读登录后才能看的页面（评论）

单纯抓搜索页/商品页用 curl 就够。Playwright 只在上述三种情况下启用。

本机 Playwright 1.65.1 装在 `/tmp/mr-probe`（临时目录，重启会丢）；要长期用就装到 skills 目录下，并复用本机 Chrome（`channel: 'chrome'`，不必下载 chromium）。

## 八、商品页三个新字段的实测记录

ASIN `B0C5HSCS8J`。2026-11-24 的交接样本返回 HTTP 200，HTML 为 2,238,048 字节。
本次复测于 `2026-11-24T21:26:38+08:00` 完成，返回 HTTP 200，保存的 HTML 为 2,241,998 个 UTF-8 字节。
两次抓取的三个页面原文一致。

| 字段 | 页面原文 | 取值位置 |
|---|---|---|
| `date_first_available` | `Date First Available : July 13, 2023` | 商品详情中的 `li` |
| `sold_by` | `Sold by MateeyLife` | `Sold by` 对应的 `offer-display-feature-text` |
| `ships_from` | `Ships from Amazon` | `Ships from` 对应的 `offer-display-feature-text` |

这次的 `fulfillment` 由发货方 `Amazon` 得到 `fba`。上述三个字段缺失时返回 `null`，并在
`degraded` 列出字段名。发货方缺失时，`fulfillment` 为 `unknown`。

未登录商品页的缺口仍为星级分布、`Customers say` AI 摘要和评论原文。星级分布只有
`reviewCountTextLinkedHistogram` 类名，评论页在交接实测中以 HTTP 302 跳转到 `/ap/signin`。
脚本在 `degraded` 记录这三项缺口。

## 九、AliExpress 美国区实测记录

2026-11-24 21:25:52（Asia/Shanghai）保存了 `pet slow feeder` 的美国区搜索页。系统
`curl` 直连 `https://www.aliexpress.com/w/wholesale-pet-slow-feeder.html`，带区域 cookie
`aep_usuc_f=site=glo&c_tp=USD&region=US&b_locale=en_US`，返回 HTTP 200，HTML 共 901,302 字节。

| 项目 | 原样本 |
|---|---|
| 页面语言 | `lang="en"` |
| 商品列表中的 `US $` 命中 | 114 次 |
| 唯一商品链接 `aliexpress.com/item/<id>.html` | 60 个 |
| 成交文案样本 | `11 sold` / `36 sold` / `13 sold` / `31 sold` / `19 sold` / `293 sold` |

`salePriceAmount` 的单位是分。样本前五条的 `382` / `391` / `342` / `109` / `343`
对应 `US $3.82` / `US $3.91` / `US $3.42` / `US $1.09` / `US $3.43`。
取价前同时核对页面语言、页面中的 `US $` 和该商品的 `formattedPrice`。
同一关键词移除区域 cookie 会得到 `lang="ja"`，`US $` 命中为 0，脚本退出且不输出商品或价格。
评分和原价始终为 `null`，美元售价直接保留 USD。

```bash
python3 fetch_aliexpress.py search "pet slow feeder" --limit 10
python3 fetch_aliexpress.py search "pet slow feeder" --limit 10 --page 2 --csv --out ./out
python3 fetch_aliexpress.py search "pet slow feeder" --html fixtures/aliexpress_us_trim.html
```

`--page` 指定本次抓取的页码。实测第 2 页返回 HTTP 200，取到 10 条商品。
脚本始终向 stdout 输出 JSON。`--out` 将 JSON 另存为 `aliexpress-search.json`，
`--csv` 另外生成 `aliexpress-search.csv`，未指定目录时写到当前目录。
