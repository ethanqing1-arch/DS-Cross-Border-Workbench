# Amazon SP-API 接入

L2 工作区里的 `scripts/spapi_fetch.py` 使用 Python 3.9 及以上版本的标准库，可按站点读取 Amazon 商品目录和 JSON 报告。

## 注册私有卖家应用

1. 用 Seller Central 主账户注册私有 SP-API 开发者，在 Solution Provider Portal 提交 Developer Profile，并申请所需操作的角色。申请卖家销售与流量报告时需要 Brand Analytics 角色。[私有开发者注册](https://developer-docs.amazon.com/sp-api/docs/register-as-a-private-developer) · [销售与流量报告角色](https://developer-docs.amazon.com/sp-api/docs/report-type-values-analytics#sales-and-traffic-business-report)
2. 在 Solution Provider Portal 打开 **Develop Apps → Add new app client**，创建用于自家卖家账户的 SP-API 应用，选好应用角色。[Amazon 应用注册步骤](https://developer-docs.amazon.com/sp-api/docs/registering-your-application)
3. 在应用的 **Edit app → LWA credentials → View** 查看 LWA 客户端 ID 和客户端密钥。[查看 LWA 凭证](https://developer-docs.amazon.com/sp-api/docs/viewing-your-application-information-and-credentials)
4. 在应用的授权页面选择目标卖家账户，点 **Authorize app**，将生成的 LWA refresh token 交给运行环境的 secret 注入机制。私有应用可在草稿状态自授权。每份授权对应一个卖家账户。[Amazon 私有应用自授权步骤](https://developer-docs.amazon.com/sp-api/docs/self-authorization)

## 给工作区进程注入凭证

在 DSH 的 secret 注入环境中使用下表左列。客户端只读取右列的进程环境变量。

| DSH 环境变量 | 客户端环境变量 |
| --- | --- |
| `DSH_SECRET_SP_API_CLIENT_ID` | `SP_API_CLIENT_ID` |
| `DSH_SECRET_SP_API_CLIENT_SECRET` | `SP_API_CLIENT_SECRET` |
| `DSH_SECRET_SP_API_REFRESH_TOKEN` | `SP_API_REFRESH_TOKEN` |

若当前 shell 已收到 DSH 注入的变量，可以用 shell 内建命令映射。关闭命令跟踪，保持实际值仅通过环境传给客户端。

```bash
set +x
export SP_API_CLIENT_ID="${DSH_SECRET_SP_API_CLIENT_ID:?}"
export SP_API_CLIENT_SECRET="${DSH_SECRET_SP_API_CLIENT_SECRET:?}"
export SP_API_REFRESH_TOKEN="${DSH_SECRET_SP_API_REFRESH_TOKEN:?}"
```

客户端通过 LWA 交换 access token，缓存到有效期结束前 60 秒。目录与报告请求依据 Amazon 官方 OpenAPI 模型。Amazon 当前的连接文档使用 LWA 请求头，本项目按交接要求额外用 LWA access token 和 client ID 生成 SigV4 请求头，签名格式采用 AWS 规范。[Amazon SP-API 连接文档](https://developer-docs.amazon.com/sp-api/docs/connecting-to-the-selling-partner-api) · [Amazon OpenAPI 模型](https://github.com/amzn/selling-partner-api-models) · [AWS SigV4 规范](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html)

## 本地验收与真实取数

无凭证也可在仓库根目录自检。自检会自动启停一个本地假服务，覆盖 LWA、目录查询、429 后重试、报告轮询、gzip 下载及 403 错误映射。

```bash
bash distribution/connectors/spapi-selftest.sh
```

**真实 Amazon 端点尚未验证，当前没有凭证。** 假服务通过只能证明本地链路与签名字段，AWS 是否接受该签名仍需验证。凭证到位后，在安装好的 L2 工作区使用默认 Amazon 端点各实跑一次，替换成有权限的站点和真实 ASIN。`--base-url` 用于本地假服务测试。

```bash
python3 scripts/spapi_fetch.py catalog --asin B0XXXXXXXX --marketplace US --out out/
python3 scripts/spapi_fetch.py report --type GET_SALES_AND_TRAFFIC_REPORT --days 30 --marketplace US --out out/
```

站点用国家码，例如 `US`、`UK`、`JP`，客户端自动选择区域端点和 marketplace ID。报告输入限 JSON 报告类型，`--days` 指定从当前 UTC 时间回溯的天数。目录和报告文件写入指定目录，stdout 输出一行含类型、条目数和文件路径的 JSON。[Amazon 站点 ID](https://developer-docs.amazon.com/sp-api/docs/store-identifiers) · [Amazon 区域端点](https://developer-docs.amazon.com/sp-api/docs/sp-api-endpoints)

## 常见错误

| 错误 | 含义与处理 |
| --- | --- |
| `E_SPAPI_CONFIG`（退出码 2） | 缺凭证时 stderr 仅列出缺少的变量名。核对 DSH 环境映射及脚本输入。 |
| `E_SPAPI_AUTH`（401/403，退出码 3） | Amazon 拒绝认证或授权。核对应用是否已授权目标账户和站点，检查应用角色及 LWA 凭证是否匹配。 |
| `E_SPAPI_THROTTLED`（429，退出码 4） | 已触及操作限额。客户端按 `Retry-After` 重试最多三次，缺少有效值时等待 2、4、8 秒。若仍被限流，按 Amazon 的操作用量计划调整调用频率。 |
| `E_SPAPI_HTTP`（退出码 5） | 其他 HTTP 错误、报告被取消或失败，或响应格式有误。根据错误对象中的状态或字段检查请求。 |
| `E_SPAPI_IO`（退出码 5） | 无法写入结果，检查输出目录及权限。 |
| `E_SPAPI_NET`（退出码 6） | 请求失败或超时。报告状态每 5 秒查询一次，轮询上限 5 分钟。 |
