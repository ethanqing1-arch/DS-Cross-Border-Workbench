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

**当前实测基线（我刚跑的，brief-24 之后）**：

```
verify.sh             == 汇总: PASS=96 FAIL=0 WARN=1 ==   RESULT: READY
installer-selftest.sh == 汇总: PASS=11 FAIL=0 ==          RESULT: READY
flow-smoke.sh         == 汇总: PASS=9 FAIL=0 WARN=3 ==    RESULT: READY
```

**写回文档的数必须是这一单做完后的最终实测值**（T5 会新增 7i 断言，verify 的 PASS 数会从 96 往上加；不许照抄 96，也不许照抄旧值）。四处一起对齐，别只改一处：

| 文件 | 现值（错的） | 改成 |
|---|---|---|
| `README.md` | `PASS=79 FAIL=0 WARN=1` | 你最后跑出来的 verify 实测值 |
| `README.md` | `PASS=6 FAIL=0` | installer-selftest 最终实测值（本单不加断言，应为 11） |
| `docs/roadmap.md` 装行与核查行 | `PASS=79` / `PASS=6` | 同上两个最终值 |
| `docs/external-setup.md` verify 基线 | `PASS=79` | verify 最终值 |

改完在收尾写清楚：最终 verify 是 `PASS=<N>`，其中几条是本单 7i 新增的（写清 N−96 等于几条）。

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
7. `grep -rn "PASS=79" README.md docs/` 的结果：除 `docs/codex-dev-brief-*.md` 历史交接单外必须零命中；再贴 `grep -n "<verify 最终数>\|<installer 最终数>" README.md docs/roadmap.md docs/external-setup.md` 证明四处都对上。

### 2026-11-25 实测收尾

#### 验收原文

`bash distribution/verify.sh`

```text
-- 7i. 月搜索量适配
  PASS 7i.1 离线 mock 填入月搜索量 12345，保留其它列并注明来源
  PASS 7i.2 空报表、无有效数据或日期与整月不符时留空，stderr 有原因
  PASS 7i.3 就地补数后需求由代理转为一级，打分证据等级 C → B
  PASS 7i.4 无凭证时非零退出，stderr 列出缺项，候选表逐字节保持原样
== 汇总: PASS=100 FAIL=0 WARN=1 ==
RESULT: READY
```

`bash distribution/flow-smoke.sh`

```text
== 汇总: PASS=9 FAIL=0 WARN=3 ==
RESULT: READY
```

`bash distribution/installer-selftest.sh`

```text
== 汇总: PASS=11 FAIL=0 ==
RESULT: READY
```

本单新增 7i 四条断言，最终 verify 为 `PASS=100`，`100 − 96 = 4`。verify 的 1 条 WARN 来自 Amazon 前台真实样本断言跳过，flow-smoke 的 3 条 WARN 来自插件缺源。全平台安装及 `--check` 分别为 `RESULT: READY（PASS=9 FAIL=0）`。Python 3.9.6 临时副本的四项变异分别被对应断言拦截，覆盖数值偏差、空报表填 0、继续使用需求代理和缺凭证仍写表。

#### Amazon 官方报表契约

[Analytics Reports · Search Query Performance Report](https://developer-docs.amazon.com/sp-api/docs/report-type-values-analytics#search-query-performance-report) 中的关键原文如下。

> `reportType` value: `GET_BRAND_ANALYTICS_SEARCH_QUERY_PERFORMANCE_REPORT`
>
> `asin` (Required)
>
> `reportPeriod`(Required)
>
> must correspond to valid first and last days in the specified `reportPeriod`.

`createReport` 参数定义将 `reportType` 和 `marketplaceIds` 标为 `required`。本脚本每份报表请求一个站点，设置 `reportOptions.reportPeriod=MONTH`，用空格拼接 `reportOptions.asin`，遵守 200 字符上限。用 `dataStartTime` 和 `dataEndTime` 指定上一个完整自然月的首尾日期。账号需要 Brand Analytics 角色和 Amazon Brand Registry，报表只覆盖授权品牌 ASIN 关联的搜索词。[createReport](https://developer-docs.amazon.com/sp-api/reference/createreport) · [Search Query Performance Report](https://developer-docs.amazon.com/sp-api/docs/report-type-values-analytics#search-query-performance-report)

官方 JSON Schema 将查询词和搜索量放在 `dataByAsin[].searchQueryData`，同一记录还包含 `asin`、`startDate` 和 `endDate`。示例原文如下。[Amazon 官方 JSON Schema](https://github.com/amzn/selling-partner-api-models/blob/main/schemas/reports/sellingPartnerSearchQueryPerformanceReport.json)

```json
"searchQuery": "wireless headphones",
"searchQueryScore": 5,
"searchQueryVolume": 15000
```

`searchQueryVolume` 的类型为 `integer`，官方字段说明如下。

> The number of times customers search for a query at a select time period.

Amazon Search Terms Report（`GET_BRAND_ANALYTICS_SEARCH_TERMS_REPORT`）的字段 `dataByDepartmentAndSearchTerm[].searchFrequencyRank` 给出频率排名。实际搜索次数取自 Search Query Performance 的 `searchQueryVolume`。[Amazon Search Terms Report](https://developer-docs.amazon.com/sp-api/docs/report-type-values-analytics#amazon-search-terms-report)

范围例外采用交接单允许的真实缺陷修复。原 `SPAPI.report(report_type, days)` 无法提交上述必填报表选项与自然月边界。调用现在可以传入日期和 `reportOptions`，共用已有的创建、轮询与文档下载流程。SP-API 请求与 LWA、文档下载的 HTTP 403 可在关键词脚本中分辨。

#### 禁网 mock 与打分原文

在临时安装工作区用系统禁网运行 `keyword_volume.py --mock`。候选原有字段逐列比较一致，新增了月搜索量来源。

补数前

```csv
品类,商品名,关键词,预估售价,月搜索量,搜索结果总数,广告密度,评论数中位数,评论数>1000占比,评分中位数,Amazon证据状态,差异化点
家居,desk cable clips,,25,,9200,0.25,45,0.05,4.2,Amazon 商品页证据不全,"可开合,免工具"
```

补数后

```csv
品类,商品名,关键词,预估售价,月搜索量,搜索结果总数,广告密度,评论数中位数,评论数>1000占比,评分中位数,Amazon证据状态,差异化点,月搜索量来源
家居,desk cable clips,,25,12345,9200,0.25,45,0.05,4.2,Amazon 商品页证据不全,"可开合,免工具",SP-API Brand Analytics
```

`score_products.py` 中同一条候选从需求代理 C 升至一级需求证据 B。补数前和补数后的打分行如下。

```csv
商品名,品类,预估售价,表面毛利,贡献利润,贡献利润率,分层,月搜索量,在售竞品数,供需比,退货率,总分,决策,诊断,红线,差异化点,证据等级,可算维度,缺口
desk cable clips,家居,25.00,,,,,,,,,64.4,小批量观察,需求代理：搜索结果总数及广告密度/利润未验/Amazon 商品页证据不全,利润未验,"可开合,免工具",C,2/4,利润未验缺少或无有效值：1688进价、运费、平均退货率；风险缺少或无有效值：平均退货率、供应稳定性分（后备缺少或无有效值：上架月龄中位数、FBA占比）
desk cable clips,家居,25.00,,,,,12345,,,,50.9,小批量观察,利润未验/Amazon 商品页证据不全,利润未验,"可开合,免工具",B,2/4,利润未验缺少或无有效值：1688进价、运费、平均退货率；风险缺少或无有效值：平均退货率、供应稳定性分（后备缺少或无有效值：上架月龄中位数、FBA占比）
```

真实环境缺少 SP-API 凭证。无凭证 CLI 实测退出码 `2`，`cmp` 确认候选 CSV 逐字节一致。真实请求分支通过本地 HTTP 服务核验了 LWA、月报请求、轮询、gzip 下载、空报表及 HTTP 403。线上 Brand Analytics 报表尚未拉取。无凭证的 stderr 原文如下。

```text
E_SPAPI_CONFIG missing: SP_API_CLIENT_ID, SP_API_CLIENT_SECRET, SP_API_REFRESH_TOKEN
```

#### 卖家精灵与 1688

卖家精灵结论为**可以接**，官方付费关键词趋势 API 的 `data[].search` 返回整数搜索量，`data[].time` 给出月份。本单交付调研文档。[关键词选品趋势接口](https://open.sellersprite.com/api/11) · [API 定价](https://open.sellersprite.com/pricing/api/keyword) · [调研文档](seller-sprite-research.md)

凭证文档与路线图均明确 1688 进价只能人工填。工作台没有可直接获取实际采购价的公开 API，商品价格页面需登录且有反爬限制。[1688 开放平台](https://aop.alibaba.com/)

#### 文档数字与工作区

`grep -rn "PASS=79" README.md docs/` 仅命中 `docs/codex-dev-brief-20.md`、`docs/codex-dev-brief-25.md`，过滤交接单后零命中。

以下为 `grep -n "PASS=100 FAIL=0 WARN=1\|PASS=11 FAIL=0" README.md docs/roadmap.md docs/external-setup.md` 的原文。README 的代理自检行也匹配了 `PASS=11 FAIL=0` 前缀，目标数字位于另外六行。

```text
README.md:77:| `distribution/verify.sh` | `PASS=100 FAIL=0 WARN=1` / `READY`（2026-11-25 实测，1 条 WARN 来自跳过 Amazon 真实样本断言） |
README.md:78:| `distribution/installer-selftest.sh` | macOS `PASS=11 FAIL=0` / `READY`（2026-11-25 实测，含 DMG 卷标校验） |
README.md:83:| `farm/scripts/proxy-selftest.sh --worker-proxy` | `PASS=11 FAIL=0 WARN=0 INFO=1` / `READY`（Camoufox worker 经代理连到假上游，venv 缺失时 WARN 跳过） |
docs/roadmap.md:16:| 装 | 通 | `bash distribution/verify.sh` → `PASS=100 FAIL=0 WARN=1` / `RESULT: READY`（2026-11-25 本机实测，1 条 WARN 来自跳过 Amazon 真实样本断言）。ZIP 和 DMG 通过验收。[发布清单](release-checklist.md) |
docs/roadmap.md:132:bash distribution/verify.sh                                   # PASS=100 FAIL=0 WARN=1 / READY（WARN 是 Amazon 真实样本断言跳过）
docs/roadmap.md:133:bash distribution/installer-selftest.sh                       # macOS：PASS=11 FAIL=0 / READY（含 DMG 卷标校验）
docs/external-setup.md:246:distribution/verify.sh                     PASS=100 FAIL=0 WARN=1 / READY（WARN 是 Amazon 真实样本断言跳过）
```

`diff -qr distribution/l2/skills distribution/l2/bundle/skills` 零差异。现有打包器通过 Git 路径清单取文件，两个新增路径用 `git add -N` 登记以覆盖发行包验收，暂存区无文件内容。改动停在工作区供验收。
