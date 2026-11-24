---
name: ecom-sp-api
description: 通过 Amazon Selling Partner API 获取官方商品目录和卖家销售流量报告。用于查询 ASIN 摘要或属性，以及按站点和时间范围提取销售与流量数据。
---

# Amazon SP-API 取数

需要 Amazon 官方商品目录、销售或流量数据时使用。目录输入是 10 位 ASIN 和站点国家码。报告输入是 JSON 报告类型、回溯天数和站点国家码。两个命令的站点默认 `US`。

在团队工作区根目录运行。用需要查询的真实 ASIN 替换示例中的占位值。

```bash
python3 scripts/spapi_fetch.py catalog --asin B0XXXXXXXX --marketplace US --out out/
python3 scripts/spapi_fetch.py report --type GET_SALES_AND_TRAFFIC_REPORT --days 30 --marketplace US --out out/
```

- `catalog` 输出 `out/catalog-<ASIN>-<站点>.json`，包含目录响应的 `summaries` 和 `attributes`（以 Amazon 返回为准）。
- `report` 输出 `out/report-<报告类型>-<站点>-<天数>d.json`，内容为解压后的报告。销售与流量报告的条目数是按日期与按 ASIN 两个数组的行数之和。
- 成功时 stdout 只有一行 JSON 摘要，含类型、条目数和输出路径。同名结果会被替换。

凭证由进程环境注入，变量为 `SP_API_CLIENT_ID`、`SP_API_CLIENT_SECRET`、`SP_API_REFRESH_TOKEN`。实际值只经过环境和内存。配置日志、聊天消息、命令参数和工作区文件里只使用变量名。遇到缺凭证，在仓库根目录用 `bash distribution/connectors/spapi-selftest.sh` 检查本地假服务链路，并明确回复真实 Amazon 取数尚未验证。测试数据仅供自检。

| stderr 错误码 | 退出码 | 处理 |
| --- | --- | --- |
| `E_SPAPI_CONFIG` | 2 | 补齐点名的变量或修正输入 |
| `E_SPAPI_AUTH` | 3 | 401/403，检查授权账户、应用角色和站点 |
| `E_SPAPI_THROTTLED` | 4 | 429 已重试三次，按接口配额稍后再跑 |
| `E_SPAPI_HTTP` | 5 | 其他 HTTP 失败、报告取消或失败、响应格式异常 |
| `E_SPAPI_IO` | 5 | 检查输出目录及写入权限 |
| `E_SPAPI_NET` | 6 | 检查网络或报告轮询超时 |

429 优先按 `Retry-After` 等待，无有效值时依次退避 2、4、8 秒。报告每 5 秒轮询一次，最多 5 分钟。
