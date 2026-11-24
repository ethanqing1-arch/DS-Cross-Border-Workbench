# 平台接入清单

除 Amazon 外，六个平台包（eBay、Walmart、TikTok Shop、AliExpress、Lazada、Shopee）各自接什么、参考哪个件、许可怎么算、怎么验、还缺什么。本文只做登记与排序，不含实现。

## 现状（2026-11-24 核查）

| 平台包 | skills | 声明的 connector |
| --- | --- | --- |
| ebay | `inherit-l2`，count=0 | `ebay-api`、`browser-farm` |
| walmart | `inherit-l2`，count=0 | `walmart-marketplace-api`、`browser-farm` |
| tiktokshop | `inherit-l2`，count=0 | `tiktok-shop-api`、`browser-farm` |
| aliexpress | `inherit-l2`，count=0 | `aliexpress-open-api`、`browser-farm` |
| lazada | `inherit-l2`，count=0 | `lazada-open-api`、`browser-farm` |
| shopee | `inherit-l2`，count=0 | `shopee-open-api`、`browser-farm` |

六个包都只有平台身份与参数占位：`skills/` 下各 1 个 `.gitkeep`，没有平台专项 skill，也没有 API 取数代码。`distribution/connectors/platforms/*.json` 是页面探针配置（T3 只读调研，靠农场浏览器），不是 API 客户端；其中 eBay 那条 2026-11-23 直连被拦，标了未验证。

Amazon 是唯一接了真数据的平台：`distribution/connectors/spapi_mock.py` + `spapi-selftest.sh` + L2 工作区 `scripts/spapi_fetch.py`，skill 目录 8 个（`00-router` … `07-system`）。

## 统一接法

照 Amazon SP-API 已验证的路子，每个平台五件套：

1. `distribution/connectors/<platform>_mock.py`：本地假服务，不联网
2. `distribution/connectors/<platform>-selftest.sh`：起停假服务并断言，进 `distribution/verify.sh`
3. `distribution/l2/workspace/scripts/<platform>_fetch.py`：零依赖客户端，只用 Python 3.9 标准库
4. `distribution/l2/skills/ecom-<platform>/SKILL.md`：同步到 `bundle/skills/`，并更新 `distribution/l2/manifest.json` 的 skills 计数
5. `docs/<platform>-setup.md`：注册步骤、凭证环境变量、错误码表

客户端不引 pip 包：发行包要能离线装，SP-API 客户端就是纯标准库。

## 六平台

### eBay

- 鉴权：OAuth 2.0 client credentials grant 换 Application access token，公开数据类接口用这档够（[eBay access token types](https://developer.ebay.com/api-docs/static/oauth-token-types.html)）。
- 参考件：[eBay/ebay-oauth-python-client](https://github.com/eBay/ebay-oauth-python-client)，Python，102★，Apache-2.0（拉 `LICENSE.txt` 原文核过），最后提交 2024-05-09；官方维护，但两年没动。
- 接法：token 端点 + Basic 头，标准库几十行；商品读取走 Browse API。
- 成本：**S**
- 缺口：Browse API 文档页这次直连返回 403（`developer.ebay.com/develop/api/buy/browse_api`），没取回，接入前在开发者站人工确认；需要开发者账号与生产 keyset。

### TikTok Shop

- 鉴权：请求签名 HMAC-SHA256（app_key + timestamp + shop_cipher 等，带 `x-tts-access-token` 头）；webhook 是另一套（app_key + 原始 body）。参考件 README 自述「请求签名未对线上 API 验证」，我们照官方文档重写。
- 参考件：[isaackogan/TikTok-Shop-Api-SDKs](https://github.com/isaackogan/TikTok-Shop-Api-SDKs)，MIT（核过），6★，OpenAPI 3.1 规范 + 六个语言 SDK，最后提交 2026-11-20。仓库 2026-10 才建，星少，但规范从官方文档自动生成，适合当接口字典。
- 接法：用 spec 的路径与字段画客户端，签名自己实现，不引它的 SDK。
- 成本：**M**
- 缺口：Partner app 审核 + 店铺授权；签名口径要等真凭证才能验。

### Walmart

- 鉴权：OAuth 2.0 client credentials，`POST https://marketplace.walmartapis.com/v3/token`，Basic 头，access token 约 15 分钟有效（[Walmart 认证文档](https://developer.walmart.com/us-marketplace/lang-fr_CA/docs/authentication-onboarding-troubleshooting)）。
- 参考件：[whitebox-co/walmart-marketplace-api](https://github.com/whitebox-co/walmart-marketplace-api)，TS，32★，MIT，最后提交 2023-08-03（已停更）；备选 [highsidelabs/walmart-api-php](https://github.com/highsidelabs/walmart-api-php)，PHP，30★，BSD-3-Clause，最后提交 2024-08-08。
- 接法：token + Bearer，先读订单、库存、商品。另有一套 `WM_SEC.*` 签名头出现在 Walmart 供应商 B2B 文档里，与 Marketplace 这条是不是同一套未核，接入前以 marketplace 文档为准。
- 成本：**M**
- 缺口：Seller Center 开发者审批 + Consumer ID / 私钥；两个参考件都不是 Python，只能照文档写。

### AliExpress（速卖通）

- 鉴权：App Key + App Secret，请求参数排序后算签名（[AliExpress 签名算法](https://developer.alibaba.com/docs/doc.htm?treeId=727&articleId=120692&docType=1)），常见实现用 HMAC-SHA256，`sign_method=sha256`。
- 参考件：[moh3a/ae_sdk](https://github.com/moh3a/ae_sdk)，TS，70★，MIT，最后提交 2025-03-30。
- 接法：签名函数单独一层，商品、订单各一个读接口先跑通。
- 成本：**M**
- 缺口：开放平台应用审核；签名细节要按官方文档逐字核——参考件是实现，不是规范。

### Shopee

- 鉴权：HMAC-SHA256，base string 按接口类型拼 `partner_id + api path + timestamp`（Shop/Merchant API 再加 `access_token` 与 `shop_id`/`merchant_id`），key 是 partner key（[Shopee 签名文档](https://open.shopee.com/developer-guide/16)）。
- 参考件：[GabMalta/shopee-sdk](https://github.com/GabMalta/shopee-sdk)，Python，0★，MIT，2026-10 建、最后提交 2026-11-18，太新、零社区验证；另有 [trungdangtapcode/shopee-open-platform-mock](https://github.com/trungdangtapcode/shopee-open-platform-mock)，TS 假服务 + 455 个 API schema，但仓库没标许可，不能直接复制代码。
- 接法：签名照官方文档自己写（base string 拼法写得清楚），两个仓库只交叉验证。
- 成本：**M**
- 缺口：partner 账号审核 + 测试环境店铺。

### Lazada

- 鉴权：HMAC-SHA256，`sign` 作为 query 参数（[Lazada 调用流程](https://open.lazada.com/apps/doc/doc?nodeId=10540&docId=108136)）。
- 参考件：搜「lazada open api sdk python」0 命中，没有可信 Python 件；[easycb/easycb-go](https://github.com/easycb/easycb-go) 里有 Lazada 签名实现可照读。
- 接法：自己写，六个里最费工的。
- 成本：**L**
- 缺口：app key 审核；没有经过验证的实现。

成本档：S 约半天到一天，M 一到两天，L 两天以上（按单人估算，含自检与文档）。

## 横向件：easycb-go

[easycb/easycb-go](https://github.com/easycb/easycb-go)：Go，175★，GitHub 标 MIT（未拉 LICENSE 原文），覆盖 Lazada / TikTok Shop / Shopee / SHEIN / Ozon 五家，最后提交 2026-08-24。只当签名口径的参考读，不引——客户端是 Python 标准库，引 Go 要额外带二进制。

## 不引第三方 SDK 的理由

1. **离线可装**：pip 依赖一多，`install-all.sh` 就不再是解压即用。
2. **许可**：MIT / Apache-2.0 / BSD 混着，还要保留 NOTICE；自己写没这个问题。
3. **维护**：这些件多为个人维护、星少、说停就停（Walmart 那个 2023 年后没动），接进来等于把升级风险揽到自己身上。

## 每个平台的自检口径

照 `spapi-selftest.sh` 的形状，至少五条：

1. token 能拿到（假服务给固定 token，断言请求头/参数带上了）
2. 签名能生成（同一输入算出同一签名串，不联网）
3. 一次正常读（目录或订单，断言字段解析出来）
4. 429 后重试（断言等待序列与次数上限）
5. 错误映射（401 / 403 / 404 / 字段缺失 → 各自错误码与退出码）

假服务通过只证明本地链路，不证明平台接受这个签名——每份 setup 文档必须原样写「真实端点未验证」。

## 派单顺序

**eBay（S）→ TikTok Shop（M）→ Walmart（M）→ AliExpress（M）→ Shopee（M）→ Lazada（L）**

理由：eBay 鉴权最简单且有官方维护中的参考件；TikTok 有 MIT 规范可直接画；Walmart、AliExpress 文档齐全但要自己写客户端；Shopee、Lazada 签名绕且参考件都不硬。

## 缺口

- 六个平台都没有真实凭证，谁也没打过真端点。
- 平台包 manifest 里的 connector id（`ebay-api`、`walmart-marketplace-api` …）目前只是声明，没有代码对得上。
- eBay Browse API 文档页 403；Shopee、Lazada、AliExpress 的签名细节来自官方文档摘录，未逐字核对完整规范。
- SHEIN、Ozon 不在我们的六平台包里，只在 easycb 的覆盖列表中。

## 核查方法

- 星标 / 许可 / 最后提交：GitHub API 仓库检索，2026-11-24。
- 许可原文：eBay、TikTok Shop 两个仓库拉 `LICENSE` / `LICENSE.txt` 文本核对；easycb 只读了 API 标注。
- 平台包现状：读 `distribution/l3/platforms/*/manifest.json` 与目录计数。
