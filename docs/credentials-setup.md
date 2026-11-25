# 凭证申请与自检

在 DS Bot 打开 **Settings → Secrets**，按下表把每个凭证保存为一条密钥。名称填逻辑名，例如 `SP_API_CLIENT_ID`。DS Bot 会加上 `DSH_SECRET_` 前缀，Amazon SP-API 和 eBay 脚本优先读取带前缀的变量。前缀变量不存在时，脚本兼容同名的裸环境变量。前缀变量存在但值为空时，该项视为未配置。

## 凭证清单

| 变量名 | DS Bot Settings → Secrets 名称 | 去哪申请或领取 | 费用与审批 | 所需权限 |
|---|---|---|---|---|
| `SP_API_CLIENT_ID` | `SP_API_CLIENT_ID` | Solution Provider Portal → Develop Apps → 找到自建应用 → LWA credentials → View → Client ID | 需 Amazon 专业卖家账号，开发者资料及角色需审核。账号费用按站点 | 读取目录用 Product Listing。报表角色见下文 |
| `SP_API_CLIENT_SECRET` | `SP_API_CLIENT_SECRET` | 同一应用 → LWA credentials → View → Client Secret | 同一 Amazon 应用，无单独凭证费用 | 与 Client ID 属于同一应用 |
| `SP_API_REFRESH_TOKEN` | `SP_API_REFRESH_TOKEN` | Solution Provider Portal → Develop Apps → 找到同一应用 → Authorize application → 对目标卖家账号选 Authorize app | 同一 Amazon 应用，无单独凭证费用 | 由目标卖家账号主用户自授权，沿用应用获批的角色 |
| `EBAY_CLIENT_ID` | `EBAY_CLIENT_ID` | eBay Developers Program → Your Account → Application Keys → 对应环境 → App ID (Client ID) | 开发者会员免费，生产 Browse API 需审批 | 应用令牌使用 `https://api.ebay.com/oauth/api_scope` |
| `EBAY_CLIENT_SECRET` | `EBAY_CLIENT_SECRET` | 同一环境、同一组 Application Keys → Cert ID (Client Secret) | 开发者会员免费，生产 Browse API 需审批 | 与 App ID 使用同一组密钥 |
| `GATEWAY_TOKEN` | `GATEWAY_TOKEN` | 向工作台部署方领取内部农场网关令牌。它由部署方生成和配置 | 无平台申请或审批 | 访问本部署的受保护网关接口，需使用与该网关配置一致的令牌 |

首次申请 Amazon 凭证时，由账号主用户提交私有开发者资料。入口为 Seller Central → Apps and Services → Develop Apps，或 Solution Provider Portal → Settings → Developer Profile。获批后在 Develop Apps → Add new app client 注册自用应用。亚马逊目前未实施此前宣布的 SP-API 年费和用量收费，专业卖家计划仍按站点收费。[私有开发者注册](https://developer-docs.amazon.com/sp-api/docs/register-as-a-private-developer) · [应用注册](https://developer-docs.amazon.com/sp-api/docs/registering-your-application) · [LWA 凭证](https://developer-docs.amazon.com/sp-api/docs/viewing-your-application-information-and-credentials) · [私有应用自授权](https://developer-docs.amazon.com/sp-api/docs/self-authorization) · [SP-API 收费公告](https://developer.amazonservices.com/cancellation-of-sp-api-fees)

Amazon Catalog Items 的 `getCatalogItem` 需要 **Product Listing**，销售与流量报告 `GET_SALES_AND_TRAFFIC_REPORT` 需要 **Brand Analytics**。如果调用其他报表或接口，按具体操作申请角色，例如 Customer Feedback 的部分操作接受 **Selling Partner Insights**。[SP-API 操作与角色](https://developer-docs.amazon.com/sp-api/docs/role-mappings) · [分析报表角色](https://developer-docs.amazon.com/sp-api/docs/report-type-values-analytics)

eBay 的 Sandbox 和 Production 使用不同的密钥组。启用生产密钥组前，先完成账号删除通知订阅或获准豁免。生产 Browse 取数还需按 Buy APIs 流程申请访问权限。[eBay 凭证后台](https://developer.ebay.com/api-docs/static/oauth-credentials.html) · [免费开发者会员](https://developer.ebay.com/api-docs/sell/static/dev-app.html) · [生产密钥组](https://www.developer.ebay.com/develop/guides/sell/get-started-with-ebay-apis) · [生产访问审批](https://developer.ebay.com/api-docs/buy/static/buy-requirements.html) · [Browse 搜索范围](https://developer.ebay.com/api-docs/buy/browse/resources/item_summary/methods/search)

卖家精灵有付费 API，已核对公开文档。[卖家精灵 API 调研](seller-sprite-research.md)

**1688 进价无法自动获取，只能人工填入候选表的 `1688进价`。** 工作台没有可直接获取实际采购价的公开 API，商品价格页面需要登录态且有反爬限制。[1688 开放平台](https://aop.alibaba.com/)

## Amazon 月搜索量

搜索查询表现报表需要 **Brand Analytics** 角色、Amazon Brand Registry 注册及目标站点的品牌 ASIN。候选表已有授权品牌 `ASIN` 列时脚本会读取该列，否则以可重复的 `--asin` 参数提供。将下方示例的 ASIN 换成已授权的品牌 ASIN。`--marketplace` 默认 `US`，请与候选关键词的站点一致。[Amazon 报表说明](https://developer-docs.amazon.com/sp-api/docs/report-type-values-analytics#search-query-performance-report)

```bash
python3 scripts/keyword_volume.py --candidates data/candidates.csv --asin B012345678
```

脚本请求上一个完整自然月。候选词取 `关键词` 列，粗筛生成的候选表使用 `商品名`。匹配到有效数值后写入 `月搜索量` 和 `月搜索量来源`，默认就地写入，可用 `--out` 另存。报告可能只覆盖与授权品牌 ASIN 相关的关键词。缺凭证、访问被拒或没有可用数值时，脚本输出原因并非零退出，已有候选文件保持原样。

## 自检

在已安装 L2 的工作区、同一个能读取 DS Bot 密钥的执行环境中运行：

```bash
python3 scripts/credential_check.py
python3 scripts/credential_check.py --json --env production
```

默认使用 eBay `sandbox`，用生产密钥组时指定 `--env production`。Amazon 两种模式都通过同一个 LWA 端点交换令牌。自检逐项报告配置状态、来源和连通性，每组配置齐全时验证一次令牌交换。同组有缺项时，已填写的项显示「不可达」，缺项显示「未配置」。失败时先核对整组配置和网络。目录、报表和 Browse 的权限以对应业务接口为准。

JSON 中 `source` 为 `DSH_SECRET_`、`bare` 或 `null`，`connectivity` 为 `reachable`、`unreachable` 或 `unconfigured`。五项配置齐全且两组令牌交换成功时退出码为 `0`。缺项或交换失败时为 `2`，脚本自身错误为 `1`。网关令牌的连通和鉴权可用 `/v1/sessions` 单独核验。[网关鉴权步骤](external-setup.md#3-起网关)

凭证原文只填入密钥设置。排障时可分享自检状态，避免把密钥或令牌放进命令参数、日志和工单。

## 常见错误

| 错误 | 含义与排查 |
|---|---|
| `E_SPAPI_CONFIG` | `missing` 列出缺少的 Amazon 逻辑名时，检查该项是否保存在当前 DS Bot 环境。若返回配置说明，按说明核对站点或请求参数 |
| `E_EBAY_CONFIG` | `missing` 列出缺少的 eBay 逻辑名时，补齐 App ID 和 Cert ID。若返回配置说明，按说明核对搜索词、条数或端点配置 |
| HTTP `401` | 服务拒绝认证。检查凭证是否来自同一应用、eBay 环境是否匹配、令牌是否过期或撤销。网关 `401` 时检查是否注入部署对应的令牌 |
| HTTP `403` | 服务拒绝访问该资源。检查 Amazon 应用获批角色及卖家授权，或 eBay 生产密钥组的启用状态和 Browse 访问资格 |
