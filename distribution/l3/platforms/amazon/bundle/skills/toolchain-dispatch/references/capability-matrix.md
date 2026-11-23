# 能力矩阵与调度细则（`toolchain-dispatch`）

## 1. 能力矩阵（工具 × 能取什么 × 等级上限 × 约束）

| 工具 | 能取什么 | 等级上限 | 限速 | 成本 | 典型失败 | 降级到 |
|---|---|---|---|---|---|---|
| SP-API（自家店铺） | 订单、库存、广告报表、退货、费用预览、Listing | A | 按 endpoint，订单类 0.0167 req/s、商品类 5 req/s | 免费（需开发者账号） | 401 token 过期、429 限额、403 未授权类目 | 后台导出 → 工具 |
| 卖家后台导出 | 退货率、广告 ACOS、费用、库存 | A | 人工，日更 | 免费 | 报表延迟 24 h | 工具估算 |
| 卖家精灵 | 关键词搜索量、竞品销量估算、类目 Top、ASIN 反查 | B（销量类 C） | ≥ 2 s/请求，单账号并发 1 | 订阅制 | 429、字段改版、导出上限 | Sorftime → 前台 |
| Sorftime | 类目结构、竞品库、选品库、销量估算 | B（销量类 C） | ≥ 2 s/请求 | 订阅制 | 数据滞后、类目映射错 | SIF → 前台 |
| SIF | 关键词库、ASIN 关键词反查、趋势 | B | ≥ 2 s/请求 | 订阅制 | 配额耗尽、字段缺失 | 卖家精灵 → 前台 |
| Firecrawl | 详情页/评论页转 markdown、结构化抽取 | B | 单任务 ≤ 50 页，间隔 ≥ 1 s | 按配额 | 反爬拦截、JS 未渲染、配额 | Playwright → 人工 |
| Tavily | 行业新闻、政策、供应链背景、站外趋势 | C | ≤ 10 次/分钟 | 按次 | 结果泛化、时效噪声 | 官网/公告页 |
| Playwright（自建） | 前台搜索页、BSR 榜、评论页、1688 图搜结果 | B | 单域名并发 ≤ 2，间隔 3–8 s | 服务器 + 代理 | 验证码、IP 封、结构改版 | Firecrawl → 人工 |

## 2. 字段 → 源映射（与统一数据字典逐字对应）

| 字段 | 主源 | 备源 | 估算源 | 兜底 | 目标等级 |
|---|---|---|---|---|---|
| `monthly_search_volume` | 卖家精灵 | SIF | 前台搜索建议量 | 类目均值 | B |
| `competitor_count` | Playwright 前台 | Firecrawl | 关键词结果数 | 人工 20 条 | B |
| `top_review_count` | Playwright 前台 | 卖家精灵 | 工具导出 | 前 3 均值 | B |
| `top10_share` | 卖家精灵销量估算 | Sorftime | 评论分布推算 | 0.5 中性 | B |
| `price_usd` | Playwright 前台 | SP-API（自家） | 工具导出 | 竞品中位 | B |
| `cogs_cny` | 1688 图搜人工 | 1688 关键词 | 同类均值 | — | B |
| `inbound_usd` | 货代报价 | 历史同类均值 | 5.5 USD/kg 空运 / 1.2 海运 | — | B |
| `referral_rate` | SP-API 费用预览 | 后台费率卡 | 0.15 默认 | — | A |
| `fba_fee_usd` | 后台费用预览 | 官方费率表 | 按分段估算 | — | A |
| `ad_share` | 广告报表 | — | 工具估算 | 0.30 | A |
| `return_rate` | 后台报表 | — | 类目均值 | 0.08 | A |
| `supply_stability` | 验厂 8 问人工 | — | 店铺年限/评价推算 | — | B |
| `differentiation_score` | 人工打分表 | — | — | 5.0 中性 | B |
| `ip_risk` | 人工四查 | — | — | — | B |
| `cert_required` | 人工判定 | — | — | — | B |

## 3. 凭证管理

| 项 | 口径 |
|---|---|
| 存放 | 只放环境变量：`SP_API_CLIENT_ID`、`SP_API_CLIENT_SECRET`、`SP_API_REFRESH_TOKEN`、`SELLERSPRITE_KEY`、`SORFTIME_KEY`、`SIF_KEY`、`FIRECRAWL_KEY`、`TAVILY_KEY` |
| 禁止 | 不写进仓库、不写进 `SKILL.md`、不写进日志、不打印前 6 位 |
| 最小权限 | SP-API 只申请 Sellers/Product/Reports/Finances 所需角色 |
| 轮换 | 90 天一次；401 出现即视为"需轮换"，当轮换并记 `降级记录` |
| 使用留痕 | 每次调用记工具名 + 时间 + 剩余配额，不记密钥 |
| 泄露处置 | 立即吊销 → 换新 → 复核近 7 天调用日志 |

## 4. 缓存实现

```
key   = sha1(tool + "|" + field + "|" + json.dumps(params, sort_keys=True))
path  = data/cache/<tool>/<key>.json
        {"value": ..., "source": "...", "grade": "B", "fetched_at": "2026-11-22T20:40:00+08:00", "params": {...}}
```

| 字段类型 | TTL |
|---|---|
| 搜索量 | 7 天 |
| 价格 / BSR / 库存 | 1 天 |
| 评论数 / 评论正文 | 3 天 |
| 类目结构 / 节点 | 30 天 |
| 1688 报价 | 3 天（价格波动大） |

命中缓存时 `actual_grade` 沿用缓存里的等级，`fetched_at` 沿用原时间；TTL 过期必须重取，不许"接着用"。

## 5. 错误码 → 动作

| 错误 | 分类 | 动作 |
|---|---|---|
| 401 / invalid_grant | 凭证 | 不重试 → 报"需轮换" → 换源 |
| 403 | 权限 | 不重试 → 查 scope → 换源 |
| 429 | 限速 | 指数退避 1/2/4/8 s，最多 3 次 → 仍失败则降级 |
| 5xx | 服务端 | 退避 2 次 → 降级 |
| 超时（> 20 s） | 网络 | 重试 1 次 → 降级 |
| 空结果 / 字段缺失 | 数据 | 先校验参数，再降级；记录"该源无此字段" |
| 验证码 / 封禁页 | 反爬 | 停止该域名 30 分钟 → 降级 → 记 IP 段 |

## 6. 取数计划模板

```
# 取数计划 · <run_id>

## 段 1 需求
| field | target_grade | ttl_days | 用途（哪个 skill） |
|---|---|---|---|
| monthly_search_volume | B | 7 | decision-control |

## 段 2 选源
| field | 主源 | 备源 | 估算源 | 预计耗时 |
|---|---|---|---|---|
| monthly_search_volume | 卖家精灵 | SIF | 前台建议 | 4 min |

## 段 3 执行记录
| field | 实际源 | actual_grade | cache_hit | 用时 | 备注 |
|---|---|---|---|---|---|

## 配额与凭证
| 工具 | 调用数 | 剩余配额 | 凭证状态 |
|---|---|---|---|
| 卖家精灵 | 12 | 488 | 正常 |

## 覆盖率
A __% / B __% / C __% / D __%　D 级 > 30% → 结论只能"观察/补数据"
```
