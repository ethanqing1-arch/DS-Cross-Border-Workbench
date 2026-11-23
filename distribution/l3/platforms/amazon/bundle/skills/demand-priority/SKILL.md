---
name: demand-priority
description: 把痛点排成可执行的需求优先级——频次×强度×付费意愿三维打分，配 Kano 分类（基本型/期望型/兴奋型），输出机会缺口清单与 P0/P1/P2。当用户提到「优先级」「先做哪个」「哪个痛点值得改」「Kano」「付费意愿」「机会缺口」「需求排序」「P0」时使用。
layer: 03-demand
version: 1.0.0
inputs: [pain_points.csv, keyword_universe.csv, price_band_usd, competitor_price_median_usd, category]
outputs: [demand_priority.csv, opportunity_gap.md, kano_matrix.md]
upstream: [voc-mining, amz-keyword-harvest]
downstream: [jtbd-map, profit-model, decision-control]
---

# 需求优先级：三维矩阵 + Kano

## 何时用

- 手里有 10–20 个痛点，不知道该先改哪个：要一个能开会的排序，不是又一个列表。
- 供应商说「改这个要加 0.8 USD」，要判断加这笔钱换来的优先级提升值不值。
- 要给产品定义文档定 P0 功能，需要 Kano 分类避免把「基本型」当卖点吹。
- 选品打分卡的 `differentiation_score` 不知道怎么填：本 skill 给建议值。
- 不归这里：从评论里挖痛点 → `03-demand/voc-mining`；把痛点拆成使用场景 → `03-demand/jtbd-map`；算加成本后的利润 → `05-product/profit-model`；最终上不上架 → `05-product/decision-control`。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `pain_points.csv` | `voc-mining` | 缺失：先跑上游。不得用未聚类的原始评论直接排优先级。 |
| `keyword_universe.csv` | `amz-keyword-harvest` | 缺失：`frequency_score` 只用提及频次分位，不叠加搜索量，标 C。 |
| `price_band_usd` | 同规格、同装量、同报价口径的竞品价格 P25 / median / P75 | 缺失：按 `pricing-ladder` 清洗后复算。有证据则附采集日期，无可比组则降档。 |
| `competitor_price_median_usd` | 同上 | 缺失：取价格带中位数，标 C；`wtp_score` 整体降 1 档。 |
| `category` | 输入 | 必需：决定 Kano 基准与「基本型」清单。 |
| `cost_delta_usd` | 改进项的成本增量（供应商报价） | 缺失：`improvable_score` ≤6 的按 0.50 USD 估，标 D；>6 的必须问供应商，不许估。 |

## 执行流程

1. **对齐输入**：确认 `pain_points.csv` 的 `evidence_grade` 与 `improvable_score` 已填；缺列直接停，不在这里补算。
2. **算频次分**（`frequency_score` 1–5）：用 `mention_weighted` 在本次 Top 10 内的分位——
   - 分位 ≥0.90 → 5；0.70–0.89 → 4；0.50–0.69 → 3；0.30–0.49 → 2；<0.30 → 1。
   - 若该痛点对应词的 `monthly_search_volume` ≥50000 → +0.5（上限 5）。
3. **算强度分**（`intensity_score` 1–5）：直接用 `severity`（1–5）；若 `sentiment_polarity` ≤−0.60 → +0.5（上限 5）。
4. **算付费意愿分**（`wtp_score` 1–5）：三路证据取最高档——
   - 价格带证据：竞品价格带上下四分位差 ÷ 中位数 ≥0.45 → 4；0.25–0.44 → 3；<0.25 → 2。
   - 文本证据：评论/Q&A 中出现 `would pay`、`worth the extra`、`gladly pay more`、`upgraded to` 且提及该痛点 → 4；出现 `overpriced`、`not worth` → 1。
   - 替代品证据：独立站同类改进款存在且售价高于 Amazon 中位价 ≥30% → 5。
   - 三者冲突时取最低档，并在 `wtp_basis` 写明。
5. **算机会缺口**：`gap_score = (0.40×frequency_score + 0.35×intensity_score + 0.25×wtp_score) × 2`，范围 2.0–10.0。
6. **Kano 分类**（规则见 `references/kano-scoring.md`）：
   - 基本型：提及率 ≥40%，且「缺失→1–2 星」占比 ≥30%。
   - 期望型：提及率 15–39%，且与星级线性相关 |r| ≥0.30。
   - 兴奋型：提及率 <15%，且 `intensity_score` ≥4，且现有产品满足率 <20%。
   - 无差异型：`improvable_score` ≤3 或 `gap_score` <4.0。
7. **算差异化建议值**：`differentiation_score_suggest = min(10, round(Σ(gap_score of P0 项) / max(1, count(P0)) ))`，供 05 层填字典字段 `differentiation_score`，本 skill 不改写该字段。
8. **定优先级**：
   - P0：`gap_score` ≥7.5 且 Kano ∈ {基本型, 期望型}，且 `improvable_score` ≥6。
   - P1：`gap_score` 6.0–7.4，或 `gap_score` ≥7.5 但 `improvable_score` 4–5。
   - P2：`gap_score` <6.0，或 `improvable_score` ≤3（只能文案规避）。
   - 硬规则：Kano=无差异型 → 一律 P2，无论分数。
9. **成本校验**：对 P0 项，把 `cost_delta_usd` 交给 `05-product/profit-model` 跑一次红线；触发毛利率 <30% 或贡献利润 <3 USD 的项降为 P1，并在报告写明原因。
10. **落盘**：`demand_priority.csv`、`opportunity_gap.md`（矩阵 + 缺口清单）、`kano_matrix.md`（分类依据与反例）。
11. **出结论行**：`结论：P0 N 项 / P1 N 项 / P2 N 项，建议先做 <痛点标签>（gap x.x，Kano 期望型，+成本 y.y USD）`。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 频次分档 | `frequency_score` | 按 `mention_weighted` 分位：≥0.90=5 / ≥0.70=4 / ≥0.50=3 / ≥0.30=2 / <0.30=1 |
| 强度分档 | `intensity_score` | `severity` 1–5，极性 ≤−0.60 加 0.5 |
| 付费意愿 | `wtp_score` | 价格带/文本/替代品三路取最高，冲突取最低 |
| 机会缺口 | `gap_score` | `(0.40f + 0.35i + 0.25w) × 2`，2.0–10.0 |
| P0 门槛 | 三项同时满足 | `gap_score` ≥7.5；Kano ∈{基本型,期望型}；`improvable_score` ≥6 |
| P1 区间 | `gap_score` | 6.0–7.4，或 ≥7.5 但可改进性 4–5 |
| P2 区间 | `gap_score` | <6.0，或可改进性 ≤3，或 Kano=无差异型 |
| Kano 基本型 | 提及率 / 缺失即差评占比 | ≥40% / ≥30% |
| Kano 期望型 | 提及率 / 星级相关 | 15–39% / \|r\| ≥0.30 |
| Kano 兴奋型 | 提及率 / 强度 / 满足率 | <15% / ≥4 / <20% |
| 成本红线联动 | P0 项过 `profit-model` | 毛利率 <30% 或贡献利润 <3 USD → 降 P1 |
| 建议值封顶 | `differentiation_score_suggest` | 0–10，不得超过 P0 平均 gap 的四舍五入值 |
| 样本底线 | 参与排序的痛点 | ≥5 个且总 `mention_count` ≥300，否则只出 P1/P2 不出 P0 |

算例（真实量级）：`kitchen-gadgets`，10 个痛点参与排序。

| 痛点 | f | i | w | gap | Kano | priority |
|---|---|---|---|---|---|---|
| 盖口漏水 | 5 | 5 | 4 | 9.4 | 基本型 | P0 |
| 铰链开裂 | 4 | 5 | 4 | 8.6 | 期望型 | P0 |
| 尺寸偏小 | 4 | 4 | 4 | 8.0 | 期望型 | P0（成本 +0.35 USD，过红线） |
| 清洗死角 | 3 | 3 | 3 | 6.0 | 期望型 | P1 |
| 太贵 | 4 | 3 | 1 | 5.6 | 无差异型 | P2 |

- P0 三项，`differentiation_score_suggest = round((9.4+8.6+8.0)/3) = 9`，供 05 层填 `differentiation_score`。
- 「太贵」f=4 但 w=1，gap 5.6 且无差异型 → 强制 P2。
- 结论行：`结论：P0 3 项 / P1 4 项 / P2 3 项，先做盖口漏水（gap 9.4，基本型，+成本 0.30 USD）`。

## 输出契约

- 落盘：`out/<run_id>/demand_priority.csv`、`out/<run_id>/opportunity_gap.md`、`out/<run_id>/kano_matrix.md`
- `demand_priority.csv` 列：

| 列名 | 说明 |
|---|---|
| `pain_point_id`（扩展，承上游） | 与 `pain_points.csv` 一致 |
| `cluster_label`（扩展，承上游） | 英文标签 |
| `frequency_score`（扩展） | 1–5 |
| `intensity_score`（扩展） | 1–5 |
| `wtp_score`（扩展） | 1–5 |
| `wtp_basis`（扩展） | 价格带/文本/替代品，取哪一路 |
| `gap_score`（扩展） | 2.0–10.0 |
| `kano_class`（扩展） | 基本型/期望型/兴奋型/无差异型 |
| `priority`（扩展） | P0/P1/P2 |
| `improvable_score`（扩展，承上游） | 0–10 |
| `cost_delta_usd`（扩展） | 改进成本增量 |
| `differentiation_score_suggest`（扩展） | 0–10，供 05 层填 `differentiation_score` |
| `redline_hit`（扩展） | 成本校验触发的红线，无则空 |
| `evidence_grade` | A/B/C/D |
| `collected_at` | ISO 时间戳 |

- `opportunity_gap.md` 必含：三维矩阵表（痛点 × f/i/w × gap）、P0/P1/P2 清单、每个 P0 的「改什么参数 / 加多少钱 / 谁去做 / 几天 / 验收标准」。
- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：结论（P0 几项 + 首做项）→ 证据（矩阵表 Top 5）→ 动作（例：「采购今天向 2 家供应商询硅胶圈报价，目标 ≤0.35 USD，3 个工作日回；验收：报价单含 MOQ 与打样周期」）。

## 质检清单

- [ ] 首行数据可信度声明：参与排序的痛点总数、总提及量、`evidence_grade` 分布。
- [ ] 每个 P0 同时满足三条门槛（gap / Kano / 可改进性），缺一条即降级。
- [ ] `wtp_score` 每项写了 `wtp_basis`，冲突时取最低档。
- [ ] Kano 分类有数据依据（提及率、相关系数、满足率），不是拍脑袋。
- [ ] 所有 P0 项已过 `profit-model` 红线，`redline_hit` 已填。
- [ ] `differentiation_score_suggest` 与 P0 平均 gap 一致，未超封顶。
- [ ] 无差异型项全部在 P2，未被「频次高」误升。
- [ ] 结论行的首做项带成本数字与验收标准。

## 反模式

- **只按频次排序**：`too expensive` 永远第一，但它不可改进。→ 正确：三维加权 + 可改进性硬门槛。
- **把基本型当卖点**：把「不漏水」写成主图文案，用户觉得「本来就该这样」。→ 正确：基本型只做到不掉分，卖点用兴奋型。
- **付费意愿靠猜**：直接给 4 分，无 `wtp_basis`。→ 正确：价格带差、文本证据、替代品三路取证据。
- **P0 定太多**：10 个痛点 8 个 P0，等于没排。→ 正确：P0 ≤3 项，超出按 gap 截断，其余转 P1。
- **跳过成本校验**：改进项加了 1.2 USD，贡献利润从 4.1 掉到 2.6，触红线。→ 正确：所有 P0 先过 `profit-model`。
