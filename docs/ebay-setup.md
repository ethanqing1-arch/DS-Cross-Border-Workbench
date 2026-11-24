# eBay Browse API 接入

L2 工作区的 `scripts/ebay_fetch.py` 使用 Python 3.9 及以上版本的标准库，可按站点搜索 eBay 在售商品。

## 注册并取得应用凭证

1. 注册 eBay Developers Program 账号，完成邮箱验证并接受 API 许可协议。[开发者注册](https://developer.ebay.com/signin?tab=register)
2. 登录后进入 **Your Account → Application Keys**，填写应用名称并在对应环境点击 **Create a keyset**。Sandbox 和 Production 各用自己的 keyset。在同一环境的 keyset 中取 **App ID (Client ID)** 和 **Cert ID (Client Secret)**。[eBay 应用注册说明](https://developer.ebay.com/api-docs/sell/static/dev-app.html) · [eBay OAuth 凭证说明](https://developer.ebay.com/api-docs/static/oauth-credentials.html)
3. 在该 keyset 的 **OAuth Scopes** 中确认已分配 `https://api.ebay.com/oauth/api_scope`。客户端用此 scope 发起 client credentials 请求并取得应用令牌。要在 Production 使用 Browse，按 eBay 的 Buy API 流程提交生产访问申请，获批后使用 Production keyset。[eBay OAuth 授权](https://developer.ebay.com/develop/guides/sell/authorization) · [Buy API 生产访问要求](https://developer.ebay.com/api-docs/buy/buy-requirements.html)

## 注入工作区凭证

将两个值通过 DSH 的 secret 注入机制交给运行环境。左列是 DSH 注入的环境变量名，右列是客户端读取的变量名。

| DSH 环境变量 | 客户端环境变量 |
| --- | --- |
| `DSH_SECRET_EBAY_CLIENT_ID` | `EBAY_CLIENT_ID` |
| `DSH_SECRET_EBAY_CLIENT_SECRET` | `EBAY_CLIENT_SECRET` |

当前 shell 已收到 DSH 环境变量时，用 shell 内建命令映射，关闭命令跟踪。凭证值只通过环境传给客户端。

```bash
set +x
export EBAY_CLIENT_ID="${DSH_SECRET_EBAY_CLIENT_ID:?}"
export EBAY_CLIENT_SECRET="${DSH_SECRET_EBAY_CLIENT_SECRET:?}"
```

## 本地自检与真实请求

在仓库根目录运行自检。脚本会启停本地假服务，校验 Basic 认证、Bearer 与站点头、429 重试、搜索结果和错误密钥映射。

```bash
bash distribution/connectors/ebay-selftest.sh
```

**真实 eBay Sandbox 和 Production 端点尚未验证，当前没有凭证。** 假服务通过只证明本地链路。Browse 路径 `GET /buy/browse/v1/item_summary/search`、查询参数 `q` 和 `limit`、站点头 `X-EBAY-C-MARKETPLACE-ID` 及所需 OAuth scope 已与 eBay 官方文档和 OpenAPI 核对。OAuth 端点 `POST /identity/v1/oauth2/token` 也已核对。[Browse search 参考](https://developer.ebay.com/develop/api/buy/browse_api/item/search) · [Browse OpenAPI](https://developer.ebay.com/api-docs/buy/browse/openapi/3/buy_browse_v1_oas3.json) · [OAuth client credentials](https://developer.ebay.com/develop/guides/sell/authorization)

取得 Sandbox 凭证后，在安装好的 L2 工作区运行以下两条命令。获批后使用 Production 凭证并为两条命令指定 `--env production`。`--base-url` 用于假服务测试。

```bash
python3 scripts/ebay_fetch.py token --env sandbox
python3 scripts/ebay_fetch.py search --q "wireless earbuds" --site EBAY_US --limit 20 --out out/
```

`token` 只打印有效期秒数。搜索输出 `out/ebay_search_<UTC时间戳>.json`，其中 `itemSummaries` 包含商品 ID、标题和价格（有价格时含金额字符串和币种）。搜索 stdout 只输出一行 JSON，含实际条数和文件路径。支持 `EBAY_US`、`EBAY_GB`、`EBAY_DE` 和 `EBAY_AU`，单次最多 200 条。

## 常见错误

| 错误 | 含义与处理 |
| --- | --- |
| `E_EBAY_CONFIG`（退出码 2） | 缺凭证时 stderr 只列出缺失的变量名。检查 DSH 变量映射或命令输入。 |
| `E_EBAY_AUTH`（401/403，退出码 3） | 401 时检查 Client ID、Client Secret 与 `--env` 是否属于同一个 keyset。403 时查看 keyset 的 scope 和 Buy API 访问授权。 |
| `E_EBAY_THROTTLED`（429，退出码 4） | 客户端按 `Retry-After` 最多重试三次。无有效值时依次等 2、4、8 秒。仍限流时降低调用频率或等待配额恢复。 |
| `E_EBAY_HTTP`（退出码 5） | 检查 stderr 中的 HTTP 状态、响应格式或输出目录权限。 |
| `E_EBAY_NET`（退出码 6） | 请求失败或超时，检查网络连通性。 |
