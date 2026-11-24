# Codex 交接单 9：eBay 数据源接入（照 SP-API 的路子，无凭证也要能验）

## 背景（现状是我核过的）

`docs/platform-integrations.md` 已定六平台接入顺序，eBay 排第一：OAuth 2.0 client credentials 换 Application token，公开数据接口用这档就够，六个里成本最低。

**我们没有 eBay 凭证**（Client ID / Client Secret 都没有），也没有开发者 keyset。所以验收标准同 brief-8：**对本地假服务全链跑通**；真凭证到位后只换环境变量、不改代码。交付说明必须写清「假服务通过 ≠ 真端点通过」。

**已核对的事实**：

- eBay token 端点是 `POST https://api.sandbox.ebay.com/identity/v1/oauth2/token`，`Content-Type: application/x-www-form-urlencoded`，`Authorization: Basic base64(client_id:client_secret)`（eBay 官方授权文档示例，见 `https://www.ebay.co.jp/developer/sell_app_guide/sell_authorization`）。
- Application access token 由 client credentials grant 签发；Browse API 用 Application token（来源：eBay 官方 token 类型页 `https://developer.ebay.com/api-docs/static/oauth-token-types.html` 与官方 Browse SDK 描述）。
- **Browse API 文档页我这边直连 403**（`developer.ebay.com/develop/api/buy/browse_api`），没取回。所以你**先自己取官方文档核对端点与参数**；取不到就按下面的候选实现，并在 setup 文档里标注「端点路径未与官方文档逐字核对」。
- 系统 `python3` 是 `3.9.6`；仓库业务脚本只用标准库，**不要引第三方依赖**。
- L2 三处联动：`distribution/l2/skills/<name>/SKILL.md`（源）、`distribution/l2/bundle/skills/<name>/`（镜像，`install.sh:187` 用 `diff -qr` 校验）、`distribution/l2/manifest.json` 的 `contents.skills`（`install.sh:125` 按目录数比对）。现在 skills=7，加完是 8。

## 约束（必读）

- 不要碰 `farm/`（引擎、台账、profiles、正在跑的 gateway / control）。
- 不要动 `farm/state/farm.db`、`farm/profiles/`、`~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- **不要动、也不要提交 `docs/platform-integrations.md` 和 `README.md` 里我加的那行**（工作区里有一份未提交的清单文档，是 Dev 的，别改它）。
- 只新增/修改：`distribution/l2/workspace/scripts/ebay_fetch.py`、`distribution/connectors/ebay_mock.py`、`distribution/connectors/ebay-selftest.sh`、`distribution/l2/skills/ecom-ebay/`、`distribution/l2/bundle/skills/ecom-ebay/`、`distribution/l2/manifest.json`、`distribution/verify.sh`、`docs/ebay-setup.md`、`README.md`（只加快速开始一行，见 T4）。
- 令牌/密钥只从环境变量读，不进 argv、不落文件、不打印。
- 拿不准就停，写清卡点；**不许伪造数字**。
- 改完自己 commit，只提交你改/加的文件。

---

## T1 客户端 `distribution/l2/workspace/scripts/ebay_fetch.py`

零依赖、Python 3.9 兼容。子命令：

```bash
python3 scripts/ebay_fetch.py search --q "wireless earbuds" --site EBAY_US --limit 20 --out out/
python3 scripts/ebay_fetch.py token --env sandbox        # 只打印过期秒数，不打印 token
python3 scripts/ebay_fetch.py --help
```

**认证（client credentials）**：

- `POST {base}/identity/v1/oauth2/token`；
- 头：`Content-Type: application/x-www-form-urlencoded`、`Authorization: Basic base64(client_id:client_secret)`；
- body：`grant_type=client_credentials&scope=https://api.ebay.com/oauth/api_scope`；
- 取 `access_token` / `expires_in`，进程内缓存到「过期前 60 秒」；
- 环境变量：`EBAY_CLIENT_ID`、`EBAY_CLIENT_SECRET`；缺任一个 → 退出码 2，只打印**缺哪个变量名**。

**端点与站点**：

- base 按 `--env sandbox|production`（默认 sandbox）：`https://api.sandbox.ebay.com` / `https://api.ebay.com`；
- 留 `--base-url` 覆盖（假服务用）；
- `--site` 映射 `X-EBAY-C-MARKETPLACE-ID`：`EBAY_US` / `EBAY_GB` / `EBAY_DE` / `EBAY_AU`，请求必带该头。

**读接口（候选，按官方文档核）**：

- `GET {base}/buy/browse/v1/item_summary/search?q=<q>&limit=<n>`；
- 头：`Authorization: Bearer <token>` + `X-EBAY-C-MARKETPLACE-ID`；
- 解析 `itemSummaries[]` 的 `itemId` / `title` / `price.value` / `price.currency`，落 `out/ebay_search_<timestamp>.json`。

**错误映射**（结构化 JSON 打到 stderr，退出码非 0）：

| 情况 | code | 退出码 |
|---|---|---|
| 缺环境变量 | `E_EBAY_CONFIG` | 2 |
| 401/403 | `E_EBAY_AUTH` | 3 |
| 429（重试 3 次仍失败） | `E_EBAY_THROTTLED` | 4 |
| 其他 4xx/5xx | `E_EBAY_HTTP` | 5 |
| 网络错误/超时 | `E_EBAY_NET` | 6 |

429 读 `Retry-After` 退避（无该头用 2/4/8 秒）。stdout 只打一行摘要（条目数、输出路径），**不得出现 token 字样**。

---

## T2 假服务 `distribution/connectors/ebay_mock.py`

标准库 `http.server` 起在 `127.0.0.1:<随机端口>`，端口写到文件供自检读：

- `POST /identity/v1/oauth2/token` → 校验 `Authorization: Basic` 解出来是 `mock-id:mock-secret`、form 里 `grant_type=client_credentials`；对就回 `{"access_token":"mock-token","expires_in":3600}`，错就 401；
- `GET /buy/browse/v1/item_summary/search` → 校验 `Authorization: Bearer mock-token` 与 `X-EBAY-C-MARKETPLACE-ID`；**第一次回 429 + `Retry-After: 0`**，第二次回 `itemSummaries` 两条；认证错回 401 带 eBay 风格错误体；
- `GET /_stats` → JSON 计数：`token_requests`、`browse_requests`、`throttled_count`、`last_marketplace`、`last_basic_ok`。

---

## T3 自检 `distribution/connectors/ebay-selftest.sh`

起假服务 → 用假凭证（`mock-id`/`mock-secret`）跑客户端 → 断言：

1. 缺凭证退出码 2，只点名变量；
2. `token` 跑通，mock 计数 `token_requests>=1` 且 `last_basic_ok=true`；
3. `search` 跑通（含 429 重试），`throttled_count>=1`、`browse_requests>=2`、`last_marketplace=EBAY_US`；
4. 输出文件非空、能解析出 2 条 `itemId`，stdout 摘要不含 `mock-token`；
5. 假服务对错误 secret 回 401 时，客户端给 `E_EBAY_AUTH`、退出码 3。

输出沿用现有约定：`PASS/FAIL` + `== 汇总: PASS=n FAIL=0 WARN=0 ==` + `RESULT: READY`。

**并在 `distribution/verify.sh` 加一条聚合断言**（跑 `ebay-selftest.sh` 收成一条 PASS），期望 `PASS=64 → 65`。

---

## T4 skill 与文档

1. `distribution/l2/skills/ecom-ebay/SKILL.md`：何时用（要 eBay 站内搜索结果/商品摘要时）、输入（关键词/站点/条数）、输出、环境变量、错误码、限流口径、**没凭证时怎么办**（假服务自检，别假报成功）。
2. 镜像到 `distribution/l2/bundle/skills/ecom-ebay/`（内容完全一致），`manifest.json` 的 `contents.skills` 加 `"ecom-ebay"`。
3. `docs/ebay-setup.md`：注册 eBay 开发者账号、建 keyset（sandbox / production）、拿 Client ID 与 Client Secret、scope 申请、两个值放哪（`DSH_SECRET_EBAY_CLIENT_ID`、`DSH_SECRET_EBAY_CLIENT_SECRET`）、自检命令、常见错（401/403/429）、**真实端点未验证 + 端点路径核对状态**。
4. `README.md` 快速开始节加一行指向 `docs/ebay-setup.md`（只加这一行，不动别的）。

---

## 验收（贴原文）

```bash
bash distribution/connectors/ebay-selftest.sh      # PASS=n FAIL=0 / RESULT: READY
bash distribution/verify.sh                        # PASS=65 FAIL=0 WARN=0 / READY
bash distribution/flow-smoke.sh                    # PASS=8 FAIL=0 WARN=0（回归，不许掉）
bash distribution/l2/install.sh /tmp/eb-ws          # bundle/skills 一致、skills=8
rm -rf /tmp/eb-ws
```

**交付说明里必须写明**：真实 eBay 端点未验证（无凭证）；Browse API 端点路径若未与官方文档逐字核对，要单独标出来。

---

## 回报格式

```
T1：--help 原文 + token/search 两次真实输出（假服务）
T2：假服务启动与 /_stats 断言原文
T3：ebay-selftest 末尾原文 + verify 末尾原文 + flow-smoke 末尾原文
T4：skills/bundle/manifest 三处改动（文件:行）+ 端点核对结论
```

卡住就停在原地写清：哪一行、什么错、试过什么。
