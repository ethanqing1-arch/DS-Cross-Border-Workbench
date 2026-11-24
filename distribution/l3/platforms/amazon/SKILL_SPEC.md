# 跨境选品 Skill 包写作规范 v1（所有 skill 必须严格遵守）

本文件是整套 skill 的**唯一事实源**。写任何一个 `SKILL.md` 前先读完本文件；与本文件冲突的内容一律以本文件为准。

## 0. 定位

对标视频《20+ skills，打造跨境电商AI超级选品大师》的 7 层架构，把它落成**可直接安装、可被 agent 自动路由、每层都有硬口径**的 skill 包。
服务对象：Amazon 美国站为主、1688 为供货上游的中小卖家（月销 0–50 万美金）。
核心信条：**选品不是感觉，是四维打分 + 三层利润 + 硬红线。**

## 1. 目录与命名

```
skills/<NN>-<layer>/<skill-name>/SKILL.md
```

- `<NN>-<layer>`：`00-router` `01-data` `02-market` `03-demand` `04-competitor` `05-product` `06-delivery` `07-system`
- `<skill-name>`：小写连字符，全局唯一，动词或名词短语，**不带层前缀**（层信息在目录里）
- 每个 skill 目录下允许有 `references/`（长表格、模板、判定细则）。`SKILL.md` 控制在 120–220 行；细节外链到 `references/*.md`，不要塞进主文件。

## 2. SKILL.md 结构（缺一节 = 不合格）

```markdown
---
name: <skill-name>
description: <一句话用途>。当用户提到「<触发词1>」「<触发词2>」「<触发词3>」或需要<场景>时使用。
layer: <NN-layer>
version: 1.0.0
inputs: [<字段>, ...]          # 可读的输入，缺失时按第 4 节的降级规则处理
outputs: [<交付物>, ...]       # 落盘文件或结构化块
upstream: [<上游 skill-name>, ...]   # 没有就写 []
downstream: [<下游 skill-name>, ...]
---

# <中文标题>

## 何时用
三到五条具体场景 + 一条"不归这里"的反例（指向正确 skill）。

## 输入契约
表格：字段 / 来源 / 缺失时怎么办。**没有"必需但可缺失"的模糊表述**：要么标"必需"，要么写清降级路径。

## 执行流程
有序步骤 1..N。每步必须是**可执行动作**（去哪个页面取什么、算什么、写到哪），不是"进行分析"这类空话。
涉及外部数据的步骤，写明**取数口径**（例：取搜索结果第一页 48 个自然位里同款数量，不含广告位）。

## 判定口径
所有阈值写成表格，必须给数字。禁止"较高/偏低/适中"。

## 输出契约
- 落盘路径：`out/<run_id>/<file>`
- 字段清单（与 `engine/score.py` 的 CSV schema 对齐）
- 给用户的正文格式：先结论，再证据，再动作

## 质检清单
5–8 条可勾选的自检项，含至少一条"数据可信度声明"要求。

## 反模式
3–5 条本 skill 最容易被做错的写法，每条给出错误示例 → 正确做法。
```

## 3. 统一数据字典（字段名必须逐字一致）

`engine/score.py` 与所有 skill 共用。CSV 列：

| 字段 | 含义 | 单位/取值 |
|---|---|---|
| `sku` | 内部编号 | 文本 |
| `category` | 品类 | 文本 |
| `product` | 商品名 | 文本 |
| `cogs_cny` | 1688 含税采购价 | CNY/件 |
| `price_usd` | 售价 | 站点本币（US 为 USD） |
| `inbound_usd` | 头程+入仓分摊 | 站点本币/件 |
| `referral_rate` | 平台佣金率 | 按站点、类目、生效期取证；0.15 仅可作无源情景 |
| `fba_fee_usd` | FBA 配送费 | 站点本币/件（按尺寸分段，核对 `10-market/fx.md`，见 `skills/05-product/profit-model/references/fba-fees.md`） |
| `ad_share` | 推广费/销售额 | 0–1（新品期 0.25–0.45） |
| `return_rate` | 退货率 | 0–1 |
| `return_loss_ratio` | 退货损耗系数 | 可二次销售 0.15；不可 1.0 |
| `tariff_rate` | 关税+附加（**基数=申报货值≈cogs_usd，不是售价**） | 0–1（默认 0.25 视品类） |
| `monthly_search_volume` | Amazon 站内同站、同词月搜索量 | 次/月；站外词量、下拉建议及未校准排名另存 |
| `competitor_count` | 共同竞品集合内的在售同款数 | 个；首屏位数单列 |
| `top_review_count` | 共同可比集合内最高评论数 | 条；不混品牌专用或不兼容款 |
| `top10_share` | 共同可比集合内前 10 listing 销量 / 该集合总销量 | 0–1；评论代理另存 |
| `supply_stability` | 供应稳定性 | 0–10 |
| `differentiation_score` | 差异化可执行度 | 0–10 |
| `ip_risk` | 侵权风险 | 0–10（10=必侵权） |
| `cert_required` | 是否需认证/资质 | 0/1 |

## 4. 全局硬口径（所有 skill 不得改写）

### 4.1 三层利润模型

```
tariff      = cogs_usd × tariff_rate      # 关税基数=申报货值，禁止按售价算
毛利        = price - cogs_usd - inbound - tariff
平台与履约  = price×referral_rate + fba_fee
推广        = price×ad_share
退货损耗    = price×return_rate×return_loss_ratio
贡献利润    = price - cogs_usd - inbound - tariff - 平台与履约 - 推广 - 退货损耗
贡献利润率  = 贡献利润 / price
盈亏平衡价  P* = (cogs_usd×(1+tariff_rate) + inbound + fba_fee) / (1 - referral_rate - ad_share - return_rate×return_loss_ratio)
cogs_usd    = cogs_cny / FX          # FX 为 CNY/站点本币，US 默认读本地费表
```

红线（R1 封顶观察，已核实的 R2–R5 直接放弃）：
1. 毛利率 < 30%
2. 贡献利润率 < 8%
3. 贡献利润 < 3 USD/件的本币等值（以同一份本地费表的美元基准换算）
4. `ip_risk ≥ 7` 或 `cert_required = 1` 且卖家无资质
5. `supply_stability < 4`（断货风险不可控）

### 4.2 四维打分（权重写死 · 绝对锚定）

每个维度先把原始指标映射到 0–100，**用绝对锚点，不用 min-max**。理由：min-max 会让每一批候选里必然出现一个 100 分和一个 0 分，跨批次不可比，历史分数无法回看。

| 维度 | 权重 | 原始值 → 0–100 |
|---|---|---|
| 需求强度 | 25% | `lin(log10(月搜索量), 3.0, 5.7)`：1k→0，500k→100 |
| 竞争压力 | 25% | `密度=lin(log10(竞品数),1,4)`；`壁垒=lin(log10(头部评论),1.5,5)`；`集中=top10_share×100`；`压力=0.5×密度+0.25×壁垒+0.25×集中`；**得分=100−压力** |
| 盈利 | 30% | `绝对=lin(log1p(max(0,贡献利润的美元等值)),0,log1p(12))`；`贡献率=min(100,贡献率/0.35×100)`；`毛利率=min(100,毛利率/0.80×100)`；`得分=0.5×绝对+0.3×贡献率+0.2×毛利率` |
| 风险 | 20% | `30×(1−退货率)+30×(供应稳定性/10)+25×(差异化/10)+15×(1−ip_risk/10)` |

`lin(v,a,b) = clamp((v−a)/(b−a)×100, 0, 100)`。总分 = Σ 维度分×权重。
分档：**≥60 上架测试 / 48–59 观察 / <48 放弃**。

### 4.3 垄断度分档（`top10_share`）

| 区间 | 判定 | 含义 |
|---|---|---|
| < 0.45 | 分散 | 有冷启动窗口 |
| 0.45–0.65 | 集中 | 需差异化或价格带错位 |
| > 0.65 | 寡头 | 无供应链优势不进 |

### 4.4 数据可信度标注（强制）

任何结论必须带证据等级：
- **A 实测**：卖家后台/SP-API/付费数据源原始导出
- **B 抓取**：前台页面抓取（有采集时间戳）
- **C 估算**：类目经验值/公开指数推算
- **D 假设**：无数据，凭经验填

正文结论后标 `[A]`/`[B]`/`[C]`/`[D]`。候选 CSV 每行提供 JSON 对象 `field_evidence`，键为决策字段名，值至少含 `value`（与 CSV 单元格文本一致）、`grade`、`source`（原始文件/导出记录及定位）、`collected_at`（ISO 日期或含时区时间）和 `scope`。有估算时，来源保留公式、样本与假设。无原始记录或估算依据时标「无源」/D，留空或只在审计情景保留，禁止进入正式评分或红线判断。

定价、月搜、三项竞争指标和 FBA 另需 `site`。可接受口径依次为 `amazon_same_pack_price_band` 或 `amazon_own_price_test`、`amazon_search_monthly`、`amazon_active_comparable_listings`、`amazon_comparable_review_max`、`amazon_comparable_sales_share`、`amazon_fba_tier`。三项竞争字段须记录相同的 `cohort`。FBA 附站点、尺寸、重量、分段及费率生效日；超出工作区费表时发告警、停在补证。

分母为固定 18 个决策字段（从 `cogs_cny` 到 `has_cert`），缺失、无源、D、口径冲突按 D 计；FBA 区间冲突另设强制门禁。旧表手填 `d_share` 只可提高有效比例。D >30% 封顶观察一次；已核实的硬红线优先。任何决策字段缺证时，正式分和正式红线留空待判，`audit_score_total` 只用于复盘，再补证重跑。

同规格价格带按同站同配送地、自然位、同兼容组、同报价口径取中位和 P25–P75。每单位分母使用确认的有效主件数。市场最低值单列，套件、数量冲突和跨装量报价不用于同规格主流带。

### 4.5 SKU 分层（五档，一品只落一层）

| 层 | 规则 | 运营口径 |
|---|---|---|
| 利润款 | 结论为上架测试 且 贡献率 ≥ 20% | 主推，广告优先，可承受较高 `ad_share` |
| 引流款 | 结论为上架测试 且 8% ≤ 贡献率 < 20% 且 需求分 ≥ 70 | 拉流量与评论，`ad_share` ≤ 0.25，不追利润 |
| 常规款 | 结论为上架测试 且 不满足以上两条 | 按计划上架，稳价 |
| 观察款 | 结论为观察 | 补齐证据或复核破线项后重跑，测试投入为零 |
| 不做/清仓 | 结论为放弃 | 不备货；有库存则降价清库 |

### 4.6 CSV 列名（引擎与所有 skill 逐字对齐）

原始输入：第 3 节全部字段（`sku … cert_required`）+ `has_cert`、`field_evidence`，兼容可选 `d_share`。US 保留 `_usd` 列；非美元站点以实际币种作金额列后缀（如 `_gbp`），并显式传入站点、币种与 CNY/本币汇率。
计算列（英文 snake_case，不得改名）：

```
gross_profit_usd, gross_margin, contribution_profit_usd, contribution_margin,
breakeven_price_usd, score_demand, score_competition, score_profit, score_risk,
score_total, verdict, sku_tier, redline_flags, evidence_grade,
evidence_status, evidence_flags, decision_gates, field_evidence, audit_score_total
```

`verdict` 只允许三个值：`上架测试` / `观察` / `放弃`。
`redline_flags` 写编号及触发值，用竖线分隔。全通过写 `PASS`；缺证时写「未判定」。
红线编号：R1 毛利率<30% ｜ R2 贡献率<8% ｜ R3 单件贡献<3 USD 的本币等值 ｜ R4 侵权≥7 或无资质 ｜ R5 供应稳定性<4。

### 4.7 层间边界（防重复劳动）

- `voc-mining`（03）出**跨平台需求侧痛点 Top10**（评论+Q&A+Reddit+TikTok，全星级）。
- `negative-review-gap`（04）只吃 **1–3 星**，出**可改 BOM 的失效模式**与差异化命题。二者不各出一份 Top10。
- `web-trend-scan`（01）管**站外**（Trends/TikTok/Reddit/DTC）；`market-trend`（02）管**站内** 12 月指数、CAGR、生命周期。
- `differentiation_score` 由 05 层赋值；03 层只给建议值 `differentiation_score_suggest`。

## 5. 交付物规范

- 每次运行生成 `out/<run_id>/`，`run_id = YYYYMMDD-HHMM-<category-slug>`
- 固定四件套：`选品打分.csv`、`选品报告.md`、`选品看板.xlsx`、`决策卡.md`
- 报告首行必须是结论行：`结论：N 可做 / N 观察 / N 放弃（共 M 个候选）`

## 6. 写作风格

- 中文，短句，动宾结构。表格优先于段落。
- 每个阈值后面带单位与来源口径。
- 禁止占位符（`xxx`、`TODO`、`待补充`）出现在任何会被 agent 直接执行的位置；示例数据必须标合成示例并与实测输入隔离。
- 禁止"建议进一步分析"这类无动作结论——每条建议必须是一个**今天能做的动作**（谁、做什么、多久、验收标准）。
