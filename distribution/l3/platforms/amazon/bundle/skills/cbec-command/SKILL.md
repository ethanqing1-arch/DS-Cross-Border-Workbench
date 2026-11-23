---
name: cbec-command
description: 跨境选品总控。当用户提到「选品」「开新品」「这个品能不能做」「跑一遍选品」「跨境选品」「亚马逊选品」「帮我选几个品」「类目分析」或需要把一次新品决策从数据跑到结论时使用。
layer: 00-router
version: 1.0.0
inputs: [目标类目或商品, 目标站点, 卖家现有资源（资金/资质/供应链）, 候选清单或关键词]
outputs: [out/<run_id>/选品报告.md, out/<run_id>/选品打分.csv, out/<run_id>/选品看板.xlsx, out/<run_id>/决策卡.md]
upstream: []
downstream: [amz-keyword-harvest, market-sizing, voc-mining, competitor-deconstruct, profit-model, supply-verify, compliance-gate, decision-control, excel-report, skill-creator, toolchain-dispatch]
---

# 跨境选品总控（Router）

## 何时用

- 用户说"我想做 XX 类目 / 帮我选品 / 这个品能不能做 / 跑一遍完整选品"。
- 用户给了一批候选品（ASIN、1688 链接、关键词），要排序和结论。
- 用户只给一个模糊方向（"宠物用品""户外"），需要先缩到可打分粒度。

**不归这里**：单点问题（"这个 ASIN 卖多少钱""帮我写条 listing"）→ 直接走对应单技能，不启动全流程；已有结论只要落地执行 → 走 `supply-verify` / `excel-report`。

## 输入契约

| 字段 | 来源 | 缺失时 |
|---|---|---|
| 目标类目/关键词 | 用户 | 追问一次；仍无则用用户所在店铺 Top3 类目反推 |
| 目标站点 | 用户 | 默认 Amazon US，并在报告首行标注"站点默认 US" |
| 候选品清单 | 用户 / `amz-keyword-harvest` 产出 | 走采集层自动生成 8–12 个候选 |
| 卖家资源约束 | 用户（资金/资质/是否自有工厂） | 按"月可用现金 ≤ 5000 USD、无自有工厂、无特殊资质"假设，标 D 级 |
| 汇率 FX | 配置 | 默认 7.15，写进 `run_meta.json` |

## 执行流程

**Step 0 建档（30 秒）**
生成 `run_id = YYYYMMDD-HHMM-<类目slug>`；在 `out/<run_id>/state.json` 写入
`{"stage": 0, "inputs": {...}, "fx": 7.15, "evidence": {}}`。之后每完成一层更新 `stage`。

**Step 1 采集（01-data）**
并行触发 3 个采集技能，产出一张候选宽表（字段见 `SKILL_SPEC.md` 第 3 节）：

- `amz-keyword-harvest` → 关键词分层 + 月搜索量
- `amz-listing-scrape` → 价格/BSR/卖家数/变体/评论数
- `amz-review-harvest` → 评论样本（≥300 条/近 12 个月）
- `web-trend-scan`（可选，判断趋势与季节性时必跑）

**门禁 G1**：`monthly_search_volume`、`competitor_count`、`top_review_count`、`price_usd`、`cogs_cny` 五个字段任一缺失 > 20% 的候选 → 该候选标 D 级，最多只能给"观察"。

**Step 2 市场（02-market）**
`market-sizing` → `market-trend` → `market-entry`，产出：TAM/SAM/SOM、季度性系数、进入难度评级（易/中/难）。

**门禁 G2**：`top10_share > 0.65` 且卖家无供应链成本优势 → 整批降档为"观察"，并在报告写明"寡头市场，需成本或技术壁垒"。

**Step 3 需求（03-demand）**
`voc-mining` → `demand-priority` → `jtbd-map`，产出 Top10 痛点、P0/P1/P2 机会缺口、3 张场景卡。

**Step 4 竞品（04-competitor）**
`competitor-deconstruct` → `negative-review-gap` → `visual-strategy` → `pricing-ladder`，产出对标表、差异化命题（一句话）、定价锚点。

**Step 5 产品与决策（05-product）**
`profit-model`（三层利润 + 敏感性）→ `supply-verify`（1688 三家比价 + 供应稳定性打分）→ `compliance-gate`（侵权/认证/类目三态）→ `decision-control`（四维打分 + 三档 + Go/No-Go 卡）。

**门禁 G3**：`ip_risk ≥ 7` 或（`cert_required=1` 且无资质）→ 直接"放弃"，不再进入打分排名（保留在报告"放弃与原因"里，写清是哪一条）。

**Step 6 交付（06-delivery）**
`excel-report` 出 `选品看板.xlsx`（6 sheet），`deck-report` 出 12 页汇报骨架（用户要汇报时才跑）。

## 判定口径（路由规则）

| 用户意图信号 | 走哪条路 | 跑几层 |
|---|---|---|
| "帮我选几个品 / 不知道做什么" | 全流程 | 1→6 |
| "这个品能不能做"（给了 1 个品） | 5 层为主 | 2→6（跳过 1 的大部分，只补该品数据） |
| "帮我分析这个类目" | 市场 + 竞品 | 1→4，不出 Go/No-Go |
| "这批候选排个序"（给了 CSV/清单） | 直接打分 | 5（profit-model → decision-control） |
| "为什么上次那个品亏了" | 复盘 | 5 + `ecom-ops` 口径对齐 |
| 只给关键词/一个链接 | 先补数据 | 1，然后停，问是否继续 |

**停止条件**（满足任一即停，不硬跑）：
1. 采集层连续 2 个数据源失败，且缺口 > 50% → 停下报"数据不可用"，不做假结论。
2. 三个以上候选触发硬红线 → 停止排名，直接给"换赛道"建议 + 3 个相邻细分。
3. 用户只想要结论 → 输出 `决策卡.md` 即可，不生成 12 页 deck。

## 输出契约

```
out/<run_id>/
├── 选品报告.md      # 首行结论：N 可做 / N 观察 / N 放弃
├── 选品打分.csv     # 全字段 + 四维分 + 结论 + 红线
├── 选品看板.xlsx    # 总览/打分明细/利润瀑布/市场与竞争/动作清单/口径说明
├── 决策卡.md        # Go/No-Go + 投入上限 + 验证指标 + 止损线
└── state.json       # 阶段、输入、证据等级
```

正文回复格式固定三段：**结论行 → 3 条关键证据（带 [A]/[B]/[C]/[D]） → 今天要做的 3 个动作（谁/做什么/验收）**。

## 质检清单

- [ ] 报告首行是结论行，不是背景介绍。
- [ ] 每个候选的四维分之和按权重能复算出总分（误差 ≤ 0.2）。
- [ ] 每条红线判定都能在 CSV 的 `红线` 列找到原句。
- [ ] 数据等级已标注，D 级占比 >30% 的候选没有出现在"上架测试"里。
- [ ] 3 个动作都写了负责人、时限、验收标准。
- [ ] `run_meta.json` 里有 FX、输入文件名、候选数。
- [ ] 没有把估算写成实测（"月销 800 件"这种没来源的话不许出现）。

## 反模式

1. **跳层直出结论**：只抓了价格就给"可做"。
   正确：G1 五个字段齐了才允许进入 market 层。
2. **用毛利率拍板**：售价 20、采购 5，"毛利 75% 很好做"。
   正确：跑三层利润，看清贡献利润是否 ≥3 USD 且贡献率 ≥8%。
3. **一个品跑到底**：只评估用户提的那个品，不给对照。
   正确：至少补 2 个同类对照品，否则分数没有参照系。
4. **全流程 12 页 deck 伺候一句话问题**：用户问"能做吗"，回来一份 PPT。
   正确：先给决策卡，用户要汇报再展开。
5. **红线让步于分数**："68 分但是侵权风险 8，应该还能做吧"。
   正确：红线一票否决，分数只用于同档内排序。
