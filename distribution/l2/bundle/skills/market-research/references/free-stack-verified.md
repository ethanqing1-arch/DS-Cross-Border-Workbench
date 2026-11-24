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
2. 放弃原文，用「评分分布 + 评论总数 + 五点」做替代判断 —— 丢掉的正是「用户为什么退货」这类最有价值的信息。
3. 只看商品页顶部偶尔露出的 2–3 条评论 —— 量太少，不可作为分类依据。

没有第 4 条。任何声称"免费无登录拿全站评论"的库，实测都是过期或要付费 key。

## 五、复现命令

```bash
cd ~/.ds-bot/skills/market-research/scripts

# 搜索页 → CSV（ASIN/标题/价格/评分/评论数/是否广告）
python3 fetch_amazon.py search "pet slow feeder" --limit 20 --csv

# 商品页 → JSON（含 BSR、五点）
python3 fetch_amazon.py product B0C5HSCS8J
```

失败时的返回形状（不会编数）：

```json
{"error": "blocked_by_amazon", "degraded": true, "rows": []}
{"error": "http_503", "degraded": true, "rows": []}
```

看到 `degraded` 就写「缺口」，不许拿别的字段凑。

## 六、速率与礼貌

- 实测单次 2–5s，串行 60 个候选约 3–5 分钟
- 间隔 < 1s 连续打，约 20–30 次后开始出现 503
- `fetch_amazon.py` 内置 2 次重试 + 1.5s 退避
- 建议：每抓 10 个停 3–5 秒；需要 60 个以上就分两批，中间隔 10 分钟

## 七、Playwright 的定位（别滥用）

它比 curl 慢一倍，但能做 curl 做不到的三件事：

1. 需要点击/翻页/滚动才出现的内容
2. 需要真实浏览器指纹才能过的页面
3. 带 cookie 读登录后才能看的页面（评论）

单纯抓搜索页/商品页用 curl 就够。Playwright 只在上述三种情况下启用。

本机 Playwright 1.65.1 装在 `/tmp/mr-probe`（临时目录，重启会丢）；要长期用就装到 skills 目录下，并复用本机 Chrome（`channel: 'chrome'`，不必下载 chromium）。
