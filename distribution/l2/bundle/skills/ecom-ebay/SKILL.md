---
name: ecom-ebay
description: 通过 eBay Browse API 按关键词和站点搜索在售商品，获取商品 ID、标题、价格和币种。
---

# eBay 商品搜索

用户需要 eBay 站内搜索结果或商品摘要时使用。输入为关键词、站点和条数。站点支持 `EBAY_US`、`EBAY_GB`、`EBAY_DE`、`EBAY_AU`，默认 `EBAY_US`。单次取 1–200 条，默认 20 条。

在 L2 工作区根目录运行。默认使用 Sandbox，获准使用生产环境后传 `--env production`。

```bash
python3 scripts/ebay_fetch.py search --q "wireless earbuds" --site EBAY_US --limit 20 --out out/
python3 scripts/ebay_fetch.py token --env sandbox
```

搜索输出为 `out/ebay_search_<UTC时间戳>.json`。`itemSummaries` 数组包含各商品的 `itemId`、`title` 和 `price`（有价格时含 `value`、`currency`）。stdout 只有一行 JSON 摘要，含实际条数和输出路径。`token` 命令只输出 `expires_in` 秒数。

凭证由进程环境注入，变量名为 `EBAY_CLIENT_ID` 和 `EBAY_CLIENT_SECRET`。实际值只经过环境和内存，命令参数、日志、聊天和文件里只引用变量名。

缺凭证时，在仓库根目录运行 `bash distribution/connectors/ebay-selftest.sh` 验证本地假服务链路。向用户说明结果来自自检样例，真实 eBay 取数尚未验证。

| stderr 错误码 | 退出码 | 处理 |
| --- | --- | --- |
| `E_EBAY_CONFIG` | 2 | 补齐点名的环境变量或修正输入 |
| `E_EBAY_AUTH` | 3 | 401/403，检查 keyset 所属环境、scope 和 API 权限 |
| `E_EBAY_THROTTLED` | 4 | 429 重试用尽，降低调用频率后再试 |
| `E_EBAY_HTTP` | 5 | 检查其他 HTTP 状态、返回格式或输出目录权限 |
| `E_EBAY_NET` | 6 | 检查网络或请求超时 |

429 最多重试三次，优先按 `Retry-After` 等待，无有效值时依次等 2、4、8 秒。应用令牌只在当前进程中缓存，在有效期结束前 60 秒停止复用。
