---
name: jtbd-map
description: JTBD 场景拆解——按「谁 / 在什么场景 / 要完成什么任务 / 现有替代方案在哪失败」出场景卡，转成产品定义输入与参数目标。当用户提到「JTBD」「使用场景」「用户在什么情况下用」「场景拆解」「产品定义」「卖点从哪来」「场景卡」时使用。
layer: 03-demand
version: 1.0.0
inputs: [pain_points.csv, demand_priority.csv, reviews.csv, reddit_corpus, category]
outputs: [scenario_cards.md, jtbd_inputs.csv, requirement_map.md]
upstream: [voc-mining, demand-priority]
downstream: [decision-control, visual-strategy]
---

# JTBD 场景拆解与产品定义输入

## 何时用

- 痛点已经挖出来、优先级也排了，但产品定义文档写不出来：需要一个「谁在什么场景下要完成什么」的骨架。
- 要做差异化：同一个产品在不同场景下的失败点不同，场景卡告诉你先修哪个场景。
- 主图与文案要定场景化表达（如「小厨房台面」而不是「厨房用品」）。
- 判断一个改进项是「锦上添花」还是「解决核心任务」：看它对应哪张场景卡。
- 不归这里：挖痛点 → `03-demand/voc-mining`；排优先级 → `03-demand/demand-priority`；写文案与主图 → `06-delivery` 层；算成本 → `05-product/profit-model`。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `pain_points.csv` | `voc-mining` | 缺失：先跑上游。场景卡必须有痛点锚点，否则只是想象。 |
| `demand_priority.csv` | `demand-priority` | 缺失：场景卡只出「失败点」，不出优先级排序，标 C。 |
| `reviews.csv` | `amz-review-harvest` | 缺失：场景证据只能来自 Reddit，标 C。 |
| `reddit_corpus` | `web-trend-scan` | 缺失：只用站内证据，`source_mix` 缺 `reddit`，结论标 C。 |
| `category` | 输入 | 必需：决定场景维度（空间/人群/时间）。 |
| `max_cards` | 默认 7 | 超过 7 张时按 `evidence_count × priority` 截断。 |

## 执行流程

1. **提场景线索**：从四类语料里抽场景触发词——
   - 空间：`small apartment`、`RV`、`dorm`、`camper`、`countertop`、`tight space`；
   - 人群：`toddler`、`senior`、`roommate`、`pet owner`、`renters`；
   - 时间/事件：`morning rush`、`meal prep`、`hosting`、`road trip`、`moving`；
   - 动作：`clean up after`、`store away`、`carry to`、`set up in`。
2. **聚场景**：把线索按「人群 × 空间 × 事件」三维组合，出现 ≥5 次句子的组合立为候选场景；同义组合合并（`small apartment` = `tiny kitchen` = `studio`）。
3. **写任务陈述（job statement）**：统一句式——
   `当我 <情境> 时，我想要 <动作+对象>，这样我就能 <期望结果>，而不必 <现有方案的代价>。`
   - 禁止写产品名（不能出现「我想要一把硅胶铲」），只写任务。
   - 每张卡 1 句，≤60 个汉字。
4. **填现有替代方案**：写用户现在实际在用什么——竞品 A、厨房现有工具、纸巾、直接不做。必须来自语料，不能编。
5. **填失败点**：替代方案在该场景下具体怎么失败，必须锚到 `pain_point_id`（至少 1 个 P0/P1）。失败点要可观测（`漏到台面`、`3 个月铰链裂`），不写「体验不好」。
6. **算证据量**：`evidence_count` = 支持该场景的去重句子数；`source_mix` 记 `review/reddit/qa/tiktok` 各自条数。
7. **转产品需求**：每条失败点 → 一条 `product_requirement`（结构/材质/尺寸/包装/说明五类之一）+ 一个可测的 `parameter_target`（带数字与单位）。
   - 例：失败点「铰链 3 个月裂」→ 需求「铰链加强筋 + 金属销」→ 目标「开合 10000 次无裂，铰链壁厚 ≥2.0mm」。
8. **定场景优先级**：`scenario_priority = 该场景内最高 priority 项（P0>P1>P2）+ evidence_count 分位`；同档按 `evidence_count` 排。P0 场景最多 3 张。
9. **交叉校验**：场景卡覆盖的 P0 痛点是否全覆盖；有 P0 痛点无场景归属 → 补卡或标 `unmapped`。
10. **落盘**：`scenario_cards.md`（卡片正文）、`jtbd_inputs.csv`（结构化）、`requirement_map.md`（需求 → 参数 → 验收）。

## 判定口径

| 项 | 规则 | 数字 |
|---|---|---|
| 卡片数量 | 每品类 | 3–7 张；<3 张说明场景没拆开，>7 张按证据量截断 |
| 备选表 | 证据量 5–14 条 | 进备选不立卡，报告附一行说明 |
| 卡片拆分 | 单卡覆盖 >2 个不相关任务 | 拆成两张，避免一张卡塞多个 job |
| 证据门槛 | `evidence_count` | ≥15 条句子才立卡；5–14 条进备选表；<5 条丢弃 |
| 源覆盖 | 有效源数 | ≥2 源；单源标 C |
| 失败点锚定 | 每卡失败点数 | ≥2 条，且至少 1 条对应 P0/P1 痛点 |
| 需求可测 | `parameter_target` | 必须含数字+单位；无数字的需求退回重写 |
| 场景优先级 | P0 场景数 | ≤3 张 |
| 覆盖完整性 | P0 痛点被场景覆盖比例 | ≥80%；低于则补卡或标 `unmapped` |
| 任务陈述 | 句式 | 必须含「当我【情境】/我想要【动作】/这样【结果】/而不必【代价】」四段，缺段退回 |
| 卡片长度 | 单卡正文 | ≤200 字（不含证据引用） |
| 时间一致 | 证据时间窗 | 与上游 `review_window_months` 一致，偏差 ≤1 个月 |

算例（真实量级）：`kitchen-gadgets`，18 个痛点句簇 → 5 张场景卡。

- `SC-01 小厨房台面备菜`：`evidence_count` 128（review:96;reddit:21;qa:11），覆盖 PP-01/PP-02/PP-04 三个 P0 → `scenario_priority=P0`。
- `SC-02 房车旅行收纳`：`evidence_count` 41（review:24;reddit:17），覆盖 PP-04/PP-06 → P1。
- `SC-03 有幼儿家庭清洁`：`evidence_count` 33（review:22;qa:11），覆盖 PP-04 → P1。
- `SC-04 批量备餐分装`：`evidence_count` 19（review:12;reddit:7）→ P2，进备选表。
- `SC-05` 因 `evidence_count=8` <15，不立卡，进备选表。
- 覆盖检查：P0 痛点 3 个，全部被 SC-01 覆盖，覆盖率 100%（≥80% 达标）。
- 结论行：`结论：5 张场景卡，P0 场景 1 张（小厨房台面备菜），覆盖 3 个 P0 痛点，输出 7 条可测参数目标`。

## 输出契约

- 落盘：`out/<run_id>/scenario_cards.md`、`out/<run_id>/jtbd_inputs.csv`、`out/<run_id>/requirement_map.md`
- `jtbd_inputs.csv` 列：

| 列名 | 说明 |
|---|---|
| `scenario_id`（扩展） | `SC-01` 起按优先级顺序编号 |
| `who`（扩展） | 人群，如 `renters in studio apartments` |
| `situation`（扩展） | 空间+时间，如 `weeknight meal prep on a 60cm counter` |
| `job_statement`（扩展） | 四段式任务陈述 |
| `current_alternative`（扩展） | 现用方案，含具体品名 |
| `failure_point`（扩展） | 失败点，可观测描述 |
| `pain_point_id`（扩展） | 对应痛点编号，多个用 `;` 分隔 |
| `evidence_count`（扩展） | 支持句数 |
| `source_mix`（扩展） | `review:42;reddit:11;qa:6` |
| `product_requirement`（扩展） | 需求，五类之一 |
| `parameter_target`（扩展） | 可测目标，含数字单位 |
| `scenario_priority`（扩展） | P0/P1/P2 |
| `evidence_grade` | A/B/C/D |
| `collected_at` | ISO 时间戳 |

- `scenario_cards.md` 单卡结构：标题（场景名）→ 谁 → 情境 → 任务陈述 → 现用方案 → 失败点（带 `pain_point_id`）→ 3 条原文证据 → 产品需求与参数目标 → 优先级。
- `requirement_map.md`：需求 → 参数目标 → 验收方法 → 责任方（产品/采购/工厂）→ 时间（天）。
- `evidence_grade`、`collected_at` 为全局约定字段（规范 4.4 可信度等级 + 交付时间戳），不属于本 skill 的扩展字段。
- 给用户正文：结论（几张卡、P0 场景是哪个）→ 证据（P0 卡全文 + 失败点对应痛点）→ 动作（例：「产品今天出铰链加强筋图纸，目标壁厚 2.0mm，验收：打样开合 10000 次无裂」）。

## 质检清单

- [ ] 首行数据可信度声明：卡片数、证据总量、源覆盖、时间窗。
- [ ] 每张卡 `evidence_count` ≥15，且 ≥2 源。
- [ ] 每张卡任务陈述四段齐全，无产品名。
- [ ] 每张卡失败点 ≥2 条，且至少 1 条锚到 P0/P1 痛点。
- [ ] 每条 `parameter_target` 带数字与单位，抽 5 条核对可测。
- [ ] P0 场景 ≤3 张，且覆盖 ≥80% 的 P0 痛点。
- [ ] 未覆盖的 P0 痛点已列 `unmapped` 并说明原因。
- [ ] 证据引用可点回原 ASIN/帖子，未改写。

## 反模式

- **把产品功能当场景**：写「需要一把好用的削皮刀」——这是产品，不是任务。→ 正确：「当我一次要削 5 个土豆时，我想要 30 秒削完不打滑，这样我就能赶上做饭，而不必削到手或换刀」。
- **场景写到「家庭用户」就停**：粒度太粗，无法指导设计。→ 正确：到「两人租住 45㎡、台面 60cm、每周做 4 次饭」这一级。
- **失败点写成「体验不好」**：不可观测、不可验收。→ 正确：「削到第 3 个时刀头打滑，果皮掉一地」。
- **需求没数字**：写「更耐用」。→ 正确：「开合 10000 次无裂，壁厚 ≥2.0mm」。
- **卡片越多越好**：12 张卡等于没重点，资源摊平。→ 正确：≤7 张，P0 ≤3 张，其余进备选。
