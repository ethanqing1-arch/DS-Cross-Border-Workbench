# 卖家精灵 API 调研

2026-11-25 核对。**结论：可以接。** 卖家精灵有公开的 HTTP API 文档，按关键词查询趋势可返回整数月搜索量。调用需要开通对应 API 服务并取得密钥。本次只核对公开文档和报价，未用账号发起请求。[数据开放平台](https://open.sellersprite.com/api) · [关键词选品趋势接口](https://open.sellersprite.com/api/11)

| 项目 | 官方文档所载 |
|---|---|
| 公开接口 | 「关键词选品-趋势数据」接收必填的 `marketplace` 和 `keyword`。返回 `data[].time`（示例按月份）、`data[].search`（整数搜索量）、`data[].keywrod`（关键词，官方拼写）。[接口文档](https://open.sellersprite.com/api/11) |
| 备选接口 | 「关键词挖掘」返回 `data.items[].keyword`、`month`、`searches`（整数搜索量）和 `supplement`。官方说明补充关键词没有当月搜索量。[接口文档](https://open.sellersprite.com/api/6) |
| 鉴权 | 开放平台发放密钥，调用时放入 `secret-key` HTTP 请求头。[API 概览](https://open.sellersprite.com/api) · [密钥使用规范](https://open.sellersprite.com/help/36) |
| 费用与限流 | 关键词选品趋势公示月费 ¥2,988，40 次/分钟、40,000 次/月。关键词挖掘公示月费 ¥4,999，40 次/分钟、40,000 次/月。平台提供试用申请。[关键词 API 定价](https://open.sellersprite.com/pricing/api/keyword) |

公开文档确认了月搜索量字段和查询粒度。未找到能独立确认这些数值与 Amazon Brand Analytics 统计口径一致的公开文档。[关键词选品趋势接口](https://open.sellersprite.com/api/11)
