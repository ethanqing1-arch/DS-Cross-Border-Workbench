# Amazon 搜索限流诊断

观察窗口从 `2026-11-24T22:54:54+08:00` 到 `2026-11-24T23:03:57+08:00`，实际经过 542.159 秒。使用现有 Amazon 抓取器，以 `pet slow feeder` 请求美国站搜索页。每次只发一轮请求，关闭重试。

## 探测记录

| 请求发起时刻 | 经过秒数 | HTTP | 抓取器 stdout 原文 |
| --- | ---: | ---: | --- |
| 2026-11-24T22:54:54+08:00 | 0.005 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T22:55:54+08:00 | 60.003 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T22:56:54+08:00 | 120.005 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T22:57:54+08:00 | 180.005 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T22:58:54+08:00 | 240.004 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T22:59:54+08:00 | 300.013 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T23:00:54+08:00 | 360.006 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T23:01:54+08:00 | 420.004 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T23:02:54+08:00 | 480.005 | 503 | `{"error": "http_503", "degraded": true, "rows": []}` |
| 2026-11-24T23:03:54+08:00 | 540.004 | 200 | 见下方完整原文 |

`2026-11-24T23:03:54+08:00` 的抓取器 stdout 原文

```json
{
 "keyword": "pet slow feeder",
 "total_results_text": "5,000",
 "count": 3,
 "sponsored_count": 1,
 "ad_density": 0.333,
 "rows": [
  {
   "asin": "B0C5HSCS8J",
   "title": "MateeyLife 2-Pack Slow Feeder Dog Bowls, 2 Cups, Dog Puzzle Feeder Bowl",
   "price": "$7.64",
   "rating": 4.6,
   "reviews": "10,819",
   "sponsored": false
  },
  {
   "asin": "B084RZ1B25",
   "title": "Outward Hound Fun Feeder Slo Bowl Dog Slow Feeder, Wave, Pink, 5.8&quot;",
   "price": "$6.39",
   "rating": 4.6,
   "reviews": "135,893",
   "sponsored": false
  },
  {
   "asin": "B00L3O4JI6",
   "title": "Outward Hound Fun Feeder Slo Bowl Dog Slow Feeder, Drop, Turquoise, 8.8&quot;",
   "price": "$8.63",
   "rating": 4.6,
   "reviews": "135,893",
   "sponsored": true
  }
 ],
 "degraded": null
}
```

## 诊断结论

本轮搜索页连续 9 次返回 HTTP 503，最后一次 503 出现在 `2026-11-24T23:02:54+08:00`。`2026-11-24T23:03:54+08:00` 首次观测到 HTTP 200，抓取器返回 3 条商品卡片。搜索页在 15 分钟观察窗口内恢复。固定冷却时长未知，商品页可用性以实际抓取结果为准。

探测后，两次正式验收中的搜索又返回 HTTP 503。本轮观测到的恢复未持续。复采 Top 10 在 `2026-11-24T23:07:06+08:00` 仍返回 HTTP 503。本轮未能取到可用样本。

## 节奏验收

`fetch_amazon.py search "pet slow feeder" --limit 2 --min-interval 5 --csv` 的 curl 发起时刻

| 请求发起时刻 | 与上次相隔秒数 |
| --- | ---: |
| 2026-11-24T23:04:05.435+08:00 | — |
| 2026-11-24T23:04:10.440+08:00 | 5.004489 |
| 2026-11-24T23:04:15.445+08:00 | 5.005135 |
| 2026-11-24T23:04:20.456+08:00 | 5.011194 |

抓取器 stdout 原文

```json
{"error": "http_503", "degraded": true, "rows": []}
```

`screen_keyword.py "pet slow feeder" --top 10 --product-interval 5 --out /tmp/t2` 搜索返回 HTTP 503，实际抓取 0 个商品页。在线报告未触发提前停止。连续商品页 503 的停止条件和统计分母已通过离线控制流 fixture 验证。

在线粗筛落盘的 Amazon 搜索抓取原文

```json
{
  "error": "http_503",
  "degraded": true,
  "rows": [],
  "_collected_at": "2026-11-24T23:04:32+08:00",
  "_exit_code": 0
}
```

## 真实样本复采

`screen_keyword.py "pet slow feeder" --top 10 --product-interval 5` 的 Amazon 搜索抓取原文

```json
{
  "error": "http_503",
  "degraded": true,
  "rows": [],
  "_collected_at": "2026-11-24T23:07:06+08:00",
  "_exit_code": 0
}
```
