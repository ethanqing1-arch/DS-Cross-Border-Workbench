# Codex 交接单 8：SP-API 数据源接入（无凭证也要能验）

## 背景（现状是我核过的）

现在取数只有一条路：`distribution/connectors/farm-probe.js` 走浏览器探针，靠农场会话抓页面。这条路的缺点是反爬、封号、慢，而且拿到的是页面结构不是官方口径。亚马逊官方 SP-API 是唯一稳定、有配额、不封号的通道，应该接进来。

**我们没有 SP-API 凭证**（LWA client id / client secret / refresh token 都没有）。所以这一单的验收标准是：**对本地假服务全链跑通**；真凭证到位后只换环境变量，不改代码。这一点必须在交付说明里写清楚，不要把「假服务通过」说成「真 API 通过」。

**环境事实**：

- 系统 `python3` 是 `3.9.6`；仓库现有业务脚本只用标准库（`argparse/csv/json/math/os/sys/collections`），**不要引第三方依赖**。
- L2 结构三处联动：`distribution/l2/skills/<name>/SKILL.md`（源）、`distribution/l2/bundle/skills/<name>/`（镜像，`install.sh:187` 用 `diff -qr` 校验一致）、`distribution/l2/manifest.json` 的 `contents.skills` 数组（`install.sh:125` 按目录数比对，少一个就 FAIL）。
- 业务脚本放 `distribution/l2/workspace/scripts/`，装进工作区后是 `scripts/`。
- 令牌/密钥只从环境变量读，不进 argv、不落文件、不打印。

## 约束（必读）

- 不要碰 `farm/`（引擎、台账、profiles、正在跑的 gateway `31679` / control `99944`）。
- 不要动 `farm/state/farm.db`、`farm/profiles/`、`~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- 只新增/修改：`distribution/l2/workspace/scripts/spapi_fetch.py`、`distribution/connectors/spapi_mock.py`、`distribution/connectors/spapi-selftest.sh`、`distribution/l2/skills/ecom-sp-api/`、`distribution/l2/bundle/skills/ecom-sp-api/`、`distribution/l2/manifest.json`、`distribution/verify.sh`、`README.md`、`docs/sp-api-setup.md`。
- 拿不准就停，写清卡点；**不许伪造数字**。
- 改完自己 commit，只提交你改/加的文件。

---

## T1 客户端 `distribution/l2/workspace/scripts/spapi_fetch.py`

零依赖、Python 3.9 兼容。三个子命令：

```bash
python3 scripts/spapi_fetch.py catalog --asin B0XXXXXXX --marketplace US --out out/
python3 scripts/spapi_fetch.py report  --type GET_SALES_AND_TRAFFIC_REPORT --days 30 --out out/
python3 scripts/spapi_fetch.py --help
```

**认证（LWA refresh token）**：

- `POST https://api.amazon.com/auth/o2/token`，`grant_type=refresh_token` + `refresh_token` + `client_id` + `client_secret`（form-urlencoded）；
- 取 `access_token` / `expires_in`，进程内缓存到「过期前 60 秒」；
- 环境变量：`SP_API_CLIENT_ID`、`SP_API_CLIENT_SECRET`、`SP_API_REFRESH_TOKEN`；缺任一个 → 退出码 2，打印**缺哪个变量名**（绝不打印值）。

**签名（SigV4）**：

- `service = execute-api`，`secret_key = access_token`，`access_key_id` 用 `SP_API_CLIENT_ID`（SP-API 的惯例做法）；
- region / host 按 marketplace 映射：NA → `us-east-1` / `sellingpartnerapi-na.amazon.com`，EU → `eu-west-1` / `sellingpartnerapi-eu.amazon.com`，FE → `us-west-2` / `sellingpartnerapi-fe.amazonaws.com`；
- 请求头：`x-amz-access-token`、`x-amz-date`、`Authorization: AWS4-HMAC-SHA256 ...`；
- 留 `--base-url` 覆盖（假服务用），默认按 marketplace 拼。

**接口**（按官方 OpenAPI 模型实现，见 `amzn/selling-partner-api-models`）：

- `catalog`：`GET /catalog/2022-04-01/items/{asin}?marketplaceIds=<id>&includedData=summaries,attributes`；
- `report`：`POST /reports/2021-06-30/reports`（createReport）→ 轮询 `GET /reports/2021-06-30/reports/{reportId}` 到 `DONE`（间隔 5s，上限 5 分钟）→ `GET /reports/2021-06-30/documents/{documentId}` 拿 `url` → 下载（gzip 就解压）→ 落到 `out/`。

**错误映射**（结构化 JSON 打到 stderr，退出码非 0）：

| 情况 | code | 退出码 |
|---|---|---|
| 缺环境变量 | `E_SPAPI_CONFIG` | 2 |
| 401/403 | `E_SPAPI_AUTH` | 3 |
| 429（重试 3 次仍失败） | `E_SPAPI_THROTTLED` | 4 |
| 其他 4xx/5xx | `E_SPAPI_HTTP` | 5 |
| 网络错误/超时 | `E_SPAPI_NET` | 6 |

429 要读 `Retry-After` 退避（无该头用 2s/4s/8s）。

**输出**：JSON 落 `out/`，stdout 只打一行摘要（类型、条目数、输出路径）；**不得出现 token/secret 字样**。

---

## T2 假服务 `distribution/connectors/spapi_mock.py`

标准库 `http.server` 起在 `127.0.0.1:<随机端口>`（写端口到文件，供自检读）：

- `POST /auth/o2/token` → `{"access_token":"mock-token","expires_in":3600}`，校验 form 里有三个字段；
- `GET /catalog/2022-04-01/items/{asin}` → 返回带 `summaries` 的 JSON；**校验** `x-amz-access-token` 与 `Authorization` 里含 `AWS4-HMAC-SHA256`、`Credential=.../execute-api/.../aws4_request`，缺了回 403；
- `POST /reports/2021-06-30/reports` → 第一次返回 429 + `Retry-After: 0`，第二次 200 给 `reportId`；
- `GET /reports/2021-06-30/reports/{id}` → 前两次 `IN_PROGRESS`，第三次 `DONE`（证明轮询）；
- `GET /reports/2021-06-30/documents/{id}` → 返回指向本服务 `/docs/{id}` 的 url；
- `GET /docs/{id}` → gzip JSON 报文（证明解压路径）。

---

## T3 自检 `distribution/connectors/spapi-selftest.sh`

起假服务 → 用假凭证（`mock-id`/`mock-secret`/`mock-refresh`）跑客户端 → 断言：

1. 缺凭证时退出码 2 且只点名变量（不打印值）；
2. `catalog` 跑通，输出 JSON 含 `summaries`，stdout 摘要不含 `mock-token`；
3. `report` 跑通（含 429 重试与轮询），输出文件非空且是 JSON；
4. 假服务收到过 `AWS4-HMAC-SHA256` 签名（服务端计数，自检断言 >0）；
5. 假服务回 403 时客户端给 `E_SPAPI_AUTH`。

输出沿用现有约定：`PASS/FAIL` + `== 汇总: PASS=n FAIL=0 WARN=0 ==` + `RESULT: READY`。

**并在 `distribution/verify.sh` 里加一条聚合断言**（跑 `spapi-selftest.sh`，把它的结果收成一条 PASS），期望 `PASS=63 → 64`。

---

## T4 skill 与文档

1. `distribution/l2/skills/ecom-sp-api/SKILL.md`：何时用（要官方商品/销售数据时）、输入（ASIN/报告类型/站点）、输出、环境变量、错误码、限流口径、**没有凭证时怎么办**（用假服务自检，别假报成功）。
2. 镜像到 `distribution/l2/bundle/skills/ecom-sp-api/`（内容必须完全一致），`manifest.json` 的 `contents.skills` 加 `"ecom-sp-api"`。
3. `docs/sp-api-setup.md`：申请 SP-API 应用的步骤、拿 refresh token 的流程、三个值放哪（`DSH_SECRET_SP_API_CLIENT_ID` 等）、自检命令、常见错（403/429 各代表什么）。
4. `README.md` 快速开始节加一行指向 `docs/sp-api-setup.md`。

---

## 验收（贴原文）

```bash
bash distribution/connectors/spapi-selftest.sh     # PASS=n FAIL=0 / RESULT: READY
bash distribution/verify.sh                        # PASS=64 FAIL=0 WARN=0 / READY
bash distribution/flow-smoke.sh                    # PASS=8 FAIL=0 WARN=0（回归，不许掉）
bash distribution/l2/install.sh /tmp/sp-ws         # 能看到 bundle/skills 一致、skills=7
rm -rf /tmp/sp-ws
```

**交付说明里必须写明**：真实 Amazon 端点未验证（无凭证）；签名实现依据官方模型，假服务只证明链路与字段，不证明 AWS 会接受签名。等凭证到位后再补一次真打。

---

## 回报格式

```
T1：--help 原文 + catalog/report 两次真实输出（假服务）
T2：假服务启动与计数断言原文
T3：spapi-selftest 末尾原文 + verify 末尾原文 + flow-smoke 末尾原文
T4：skills/bundle/manifest 三处改动（文件:行）
```

卡住就停在原地写清：哪一行、什么错、试过什么。
