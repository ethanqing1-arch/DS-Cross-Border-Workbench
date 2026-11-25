# brief-22：客户自填凭证接入层

## 背景（实测，不是推测）

产品要卖给客户，客户得填**自己的**三方凭证（Amazon SP-API、eBay、以后还有卖家精灵 / 1688）。现在代码读的是不带前缀的环境变量：

```python
# distribution/l2/workspace/scripts/spapi_fetch.py:27
CREDENTIALS = {
    "client_id": "SP_API_CLIENT_ID",
    "client_secret": "SP_API_CLIENT_SECRET",
    "refresh_token": "SP_API_REFRESH_TOKEN",
}
# distribution/l2/workspace/scripts/ebay_fetch.py:29
CREDENTIALS = ("EBAY_CLIENT_ID", "EBAY_CLIENT_SECRET")
```

但 DS Bot 的安全密钥卡片注入的是带前缀的变量（用户存 `SP_API_CLIENT_ID`，shell 里拿到 `$DSH_SECRET_SP_API_CLIENT_ID`）。中间没有任何映射，`fetch_router.py:180` 读到 `DSH_SECRET_` 开头的变量只是拿去做**脱敏**（`contains_credential`），不会把 `DSH_SECRET_X` 当成 `X` 传给抓取器。

结果：**客户按最安全的方式填了凭证，管线依然读不到，直接报 `E_SPAPI_CONFIG missing`。**

这一单只做凭证接入层，**不接卖家精灵和 1688 的适配器**（那是下一单）。

## 任务

### T1 统一凭证解析

**新文件**：`distribution/l2/workspace/scripts/credentials.py`（纯标准库，兼容 3.9.6）

- 提供 `resolve(name)`：先读 `os.environ["DSH_SECRET_<name>"]`，没有再读 `os.environ["<name>"]`，都没有返回 `None`。
- 提供 `missing(names)` 之类的小工具，供报错统一格式。
- **顺序写死**：`DSH_SECRET_` 前缀优先。两者同时存在且不同时，取 `DSH_SECRET_`。

**改文件**：
- `spapi_fetch.py`、`ebay_fetch.py` 的凭证取值改走 `credentials.resolve`；
- `fetch_router.py` 的脱敏集合必须同时收两种形态（`X` 和 `DSH_SECRET_X` 的值），避免只脱敏一半；
- 错误码保持不变（`E_SPAPI_CONFIG` / `E_EBAY_CONFIG`），`missing` 列表里写**逻辑名**（`SP_API_CLIENT_ID`），不要写 `DSH_SECRET_...`。

### T2 凭证自检命令

**新文件**：`distribution/l2/workspace/scripts/credential_check.py`

```
用法：python3 scripts/credential_check.py [--json] [--env sandbox|production]
```

对每个凭证输出一行：`名称 | 已配置/未配置 | 来源(DSH_SECRET_/裸名) | 连通性`。

- 已配置的做一次**真实端点验证**：SP-API 走 LWA token 交换、eBay 走 OAuth client_credentials；拿不到网络或凭证缺失时**只报未配置/不可达，不报成功**。
- `--json` 输出机器可读结果，便于以后接安装向导。
- **输出任何情况下都不许出现凭证原文**（包括异常信息、URL、日志）。
- 退出码：全部配置且连通 `0`；有缺或不通 `2`（不许 `1`，保留给脚本自身错误）。

### T3 客户可读的凭证清单

**新文件**：`docs/credentials-setup.md`

每个凭证一行/一节，必须写清：

| 字段 | 说明 |
|---|---|
| 变量名 | `SP_API_CLIENT_ID` 这种逻辑名 |
| 在 DS Bot 里存哪 | Settings → Secrets，名称就填逻辑名 |
| 去哪申请 | 具体的开发者后台路径 |
| 是否收费 | 免费 / 要卖家账号 / 要审批 |
| 需要什么权限 | 例如 SP-API 的 Selling Partner Insights 角色 |
| 自检命令 | `python3 scripts/credential_check.py` |
| 常见错误 | `E_SPAPI_CONFIG` / `E_EBAY_CONFIG` / 401 / 403 分别意味着什么 |

覆盖现有 5 个凭证 + `GATEWAY_TOKEN`（我们自己的农场网关令牌，也要说明它不是客户申请的）。

**不许**写「卖家精灵 / 1688 已经支持」——它们还没有适配器，最多写「规划中」。

### T4 断言

**`distribution/connectors/spapi-selftest.sh`、`ebay-selftest.sh`**：保持现有裸名用例通过（向后兼容）。

**`distribution/verify.sh`** 加一节 `7g. 凭证接入层`，至少五条：

1. **只设 `DSH_SECRET_` 前缀** → `spapi_fetch` / `ebay_fetch` 能读到并走通 mock（证明前缀生效）；
2. **只设裸名** → 仍然能读到（证明向后兼容）；
3. **两者都设且值不同** → 用的是 `DSH_SECRET_` 的值（证明优先级）；
4. `credential_check.py` 的输出**不含任何凭证原文**（把 mock 凭证字符串拿去 grep，必须 0 命中）；
5. `credential_check.py` 在缺凭证时退出码为 `2`，`--json` 输出里 `configured` 字段为 false。

第 1–3 条直接用 mock 服务，不许打真实端点。

### T5 文档

- `README.md`：在「取数」或环境变量那节加一句「凭证统一通过 DS Bot Secrets 填写，脚本两种形态都认，前缀优先」。
- `docs/roadmap.md` 能力表「取数」那行跟着改。

## 范围与红线

- **只许改**：新建 `credentials.py`、`credential_check.py`、`docs/credentials-setup.md`；改 `spapi_fetch.py`、`ebay_fetch.py`、`fetch_router.py`、`spapi-selftest.sh`、`ebay-selftest.sh`、`verify.sh`、`README.md`、`docs/roadmap.md`、本交接单「收尾」。
- **不许改**：`score_products.py`、`screen_to_candidates.py`、`screen_keyword.py`、`estimate_columns.py`、`fetch_amazon.py`、`fetch_aliexpress.py`、`gen_listing.py`、`ops_report.py`、`cs_router.py`、`farm/`。
- **红线**：
  - 任何地方不许打印、写入、记录凭证原文；
  - 不许把凭证塞进命令行参数；
  - 不许打真实 SP-API / eBay 生产端点做测试（只用 mock）；
  - 不许把 `DSH_SECRET_` 前缀替换成别的命名规则，也不许反过来只认前缀（会破坏现有 selftest 和 CI）；
  - 缺凭证时不许静默降级成「没有数据但成功」。
- 镜像同步：改完 `diff -qr` 必须零差异。
- python 只用标准库、兼容 3.9.6。
- **不要 commit、不要 push**，改完停在干净工作区等我验收。

## 收尾

把下面原文追加到本文件末尾：

1. `bash distribution/verify.sh` 汇总行 + `7g` 五条原文；
2. `bash distribution/flow-smoke.sh` 汇总行；
3. `credential_check.py` 在「全配置」「全缺」两种状态下的完整输出（凭证必须是 mock 值）；
4. `grep -c` 证明输出里没有凭证原文的那条命令与结果；
5. `diff -qr` 镜像结果（应为空）。
