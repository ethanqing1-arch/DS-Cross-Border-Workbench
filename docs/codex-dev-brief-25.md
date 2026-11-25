# brief-25：第三方数据源适配（月搜索量 / 调研 / 文档数字同步）

## 背景（实测）

打分表现在四维里，「利润」卡在缺 `1688进价 / 运费 / 平均退货率`，「需求」只能用 `搜索结果总数` 当**代理**（证据等级 C）。如果能把真实 `月搜索量` 拿到手，需求维度就从代理升成一级证据，整行证据等级能从 C 升到 B。

现有条件：

- `spapi_fetch.py` 已经有报告能力（`REPORTS = "/reports/2021-06-30"`，`report(report_type, days)`，轮询 + 取 document 全都有）；
- brief-22 已经把凭证接入层做好（`credentials.py`，`DSH_SECRET_` 前缀优先、裸名兼容）；
- 候选表里 `月搜索量` 这一列现在是空的，`screen_to_candidates.py` 只填实测到的抓取列。

另外两处**文档数字已经过期**，一并对齐（别只改一处）：

```
README.md:77   verify.sh              写的 PASS=79   → 实测 PASS=93 FAIL=0 WARN=1
README.md:78   installer-selftest.sh  写的 PASS=6    → 实测 PASS=8 FAIL=0
```

## 任务

### T1 用 SP-API 拿真实月搜索量

**新文件**：`distribution/l2/workspace/scripts/keyword_volume.py`

```
用法：python3 scripts/keyword_volume.py --candidates data/candidates.csv [--out <路径>] [--mock <json>]
```

要求：

1. 先**读官方文档确认报表类型**：Amazon SP-API 的 Brand Analytics 报表（搜索词级 / ASIN 级）真实的 `reportType` 字符串、请求参数、返回列名，必须以你实际查到的文档为准，**不许凭印象编**。把你查到的文档链接和原文关键行写进交接单收尾。
2. 用已有的凭证接入层（`credentials.resolve`）读 `SP_API_CLIENT_ID / SP_API_CLIENT_SECRET / SP_API_REFRESH_TOKEN`，走 `spapi_fetch.py` 已有能力，不要另起一套 HTTP 签名。
3. 输出：给候选表补 `月搜索量` 一列（整数，真实值），并在 `Amazon证据状态` 或新列里标注来源为 `SP-API Brand Analytics`。
4. **拿不到（无凭证 / 无 Brand Analytics 权限 / 报表为空）时**：`月搜索量` 留空，不许填 0，不许用搜索结果总数顶替，并在 stderr 打印明确原因（例如 `E_SPAPI_CONFIG missing: SP_API_CLIENT_ID`、`E_SPAPI_ROLE`）。
5. `--mock <json>` 用给定 JSON 走完整解析路径，不打网络（供 selftest 用）。

**联动**：跑完 `keyword_volume.py` 后，`score_products.py` 应当把需求维度从「代理」升级为「一级」，证据等级从 C 升到 B。这条要能验证。

### T2 卖家精灵接入调研（只调研，不实现）

**新文件**：`docs/seller-sprite-research.md`

- 它有没有公开 API、要不要付费、鉴权方式、限流、返回字段里有没有月搜索量；
- 结论只能是三种之一：**可以接**（附文档链接与关键字段）/ **不公开 API 不可接** / **需商务谈**；
- **不许写代码**，不许编造端点。查不到就写「未找到公开文档」。

### T3 1688 的结论写死

在 `docs/credentials-setup.md` 和 `docs/roadmap.md` 里明确写：1688 进价**无法自动获取**（无公开 API、需要登录态、反爬），只能人工填。不许留「规划中」这种含糊说法。

### T4 文档数字同步

把实测值写回（这些数是我刚跑出来的，不要自己重编）：

| 文件 | 行 | 现值 | 改成 |
|---|---|---|---|
| `README.md` | 77 | `PASS=79 FAIL=0 WARN=1` | `PASS=93 FAIL=0 WARN=1` |
| `README.md` | 78 | `PASS=6 FAIL=0` | `PASS=8 FAIL=0` |
| `docs/roadmap.md` | 装/跑 两行 | 仍是 79 / 9 | verify `PASS=93 FAIL=0 WARN=1`、installer `PASS=8` |
| `docs/external-setup.md` | verify 基线 | 79 | 93 |

（先自己 `grep -n "PASS=79\|PASS=6" README.md docs/*.md` 核对行号，别照抄我的行号。）

### T5 断言

**`distribution/verify.sh`** 加一节 `7i. 月搜索量适配`，至少四条：

1. `--mock` 模式下，`月搜索量` 被正确填空（数字与 mock 一致）；
2. mock 为空报表时，`月搜索量` 留空且 stderr 有明确原因，**不是 0**；
3. 补上月搜索量后，`score_products.py` 的那行证据等级从 `C` 升到 `B`（需求不再走代理）；
4. 无凭证时 `keyword_volume.py` 不改动候选表的其他列、退出码非 0 且不写假数据。

## 范围与红线

- **只许改**：新建 `keyword_volume.py`、新建 `docs/seller-sprite-research.md`、`distribution/verify.sh`、`README.md`、`docs/roadmap.md`、`docs/external-setup.md`、`docs/credentials-setup.md`、本交接单「收尾」。
- **不许改**：`spapi_fetch.py`（除非发现真实 bug，须在收尾写明）、`credentials.py`、`score_products.py`、`screen_to_candidates.py`、`screen_keyword.py`、`make-bundle.sh`、`release.sh`、`farm/`。
- **红线**：
  - 拿不到数据时**绝不填 0、绝不拿搜索结果总数顶替**；
  - 不许编造 SP-API 报表类型或字段名，必须以官方文档为准并把链接写进收尾；
  - 不许在这个仓库里写任何真实凭证；
  - 卖家精灵只调研不写代码。
- **这一单不许 commit、不许 push**（上一单你自己提交了，这次改完停在工作区等验收）。
- 镜像同步：`diff -qr distribution/l2/skills distribution/l2/bundle/skills` 必须零差异。
- python 只用标准库、兼容 3.9.6。

## 收尾

把下面原文追加到本文件末尾：

1. `bash distribution/verify.sh` 汇总行 + `7i` 四条原文；
2. `bash distribution/flow-smoke.sh` 汇总行；
3. SP-API Brand Analytics 的文档链接与原文关键行（reportType、必填参数、返回列）；
4. `keyword_volume.py --mock` 前后候选表的两行原文（证明 `月搜索量` 被填、其它列没被改）；
5. 补上月搜索量后的打分表那一行（证明证据等级从 C 升到 B）；
6. 卖家精灵调研结论一句话 + 依据链接；
7. `grep -n "PASS=93\|PASS=8" README.md docs/*.md` 的结果（证明四处都对上了）。
