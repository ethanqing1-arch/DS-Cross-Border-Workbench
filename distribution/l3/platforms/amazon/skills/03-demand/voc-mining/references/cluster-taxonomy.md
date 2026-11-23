# 痛点类目树与可改进性评分

供 `voc-mining` 步骤 3、9 直接执行。痛点必须落到「可改的产品参数」这一级，否则视为无效簇。

## 1. 痛点词根（英文，按语料语言扩充）

| 大类 | 词根 |
|---|---|
| 密封/泄漏 | `leak`, `leaks`, `leaking`, `spill`, `spills`, `seep`, `not airtight`, `lid doesn't seal` |
| 结构强度 | `flimsy`, `cheap plastic`, `cracked`, `cracks`, `broke`, `broken`, `snapped`, `bent`, `wobble`, `falls apart` |
| 材质/耐用 | `rust`, `rusty`, `peeled`, `peeling`, `faded`, `stained`, `melted`, `warped`, `scratched` |
| 尺寸 | `too small`, `too large`, `doesn't fit`, `smaller than`, `bigger than`, `not as described size` |
| 清洁 | `hard to clean`, `can't clean`, `stains`, `residue`, `dishwasher safe`, `mold`, `smell`, `odor` |
| 功能失效 | `stopped working`, `doesn't work`, `won't turn on`, `no suction`, `weak`, `not powerful` |
| 装配/使用 | `instructions unclear`, `hard to assemble`, `missing parts`, `stuck`, `jammed`, `too tight`, `too loose` |
| 包装/物流 | `arrived damaged`, `dented`, `box was crushed`, `missing`, `late` |
| 价值感知 | `overpriced`, `not worth`, `cheaper elsewhere`, `waste of money` |
| 服务 | `no response`, `warranty`, `return process` |

## 2. 类目树（三层，必落到第三层）

```
密封 → 盖口 → 硅胶圈缺失 / 圈槽太浅 / 卡扣压力不足
结构 → 铰链 → 塑料铰链无加强筋 / 螺丝直接攻塑料 / 壁厚 <1.2mm
材质 → 表面 → 涂层附着力不足 / 非食品级 PP / 不锈钢标号虚标
尺寸 → 适配 → 内径与标称差 >3mm / 未标注外径 / 公差 ±5%
清洁 → 死角 → 不可拆结构 / 缝隙 >0.5mm 藏污 / 不适用洗碗机
功能 → 动力 → 电机扭矩不足 / 电池容量虚标 / 开关触点氧化
装配 → 说明 → 无图示 / 步骤 >8 步 / 零件无编号
包装 → 防护 → 无内衬 / 单层瓦楞 / 未做跌落测试
价值 → 定价 → 同规格均价高 30% / 配件另售
```

规则：一个 `cluster_label` 必须能映射到第三层的某一条；映射不到 → 归 `other`，不进 Top 10。

## 3. 可改进性评分（`improvable_score` 0–10）

五项各 0–2 分，加总：

| 维度 | 0 分 | 1 分 | 2 分 |
|---|---|---|---|
| 结构可改性 | 需重开模且结构复杂 | 改模具局部 | 换配件/加零件即可 |
| 成本增量 | >1.50 USD/件 | 0.30–1.50 | <0.30 |
| 供应链可得性 | 需新供应商开发 >60 天 | 现供应商可做，30–60 天 | 现有物料 7 天内可拿 |
| 专利/合规风险 | 有外观或实用专利 | 需做规避设计 | 无相关专利与认证 |
| 验证难度 | 需 30 天以上实测 | 7–30 天 | 打样即验证 |

分级：
- 8–10：立刻可做，进产品定义第一版。
- 6–7：可做，但需一次成本核算（进 `05-product/profit-model` 验证红线）。
- 4–5：需先做小样测试，不进首版。
- 0–3：不做产品改动，只做文案/详情页澄清（如「不适用洗碗机」写清）。

## 4. 簇质量检查

| 检查 | 不合格表现 | 处理 |
|---|---|---|
| 粒度 | `quality issue`、`bad product` | 拆到第三层；拆不动 → 丢弃 |
| 方向一致性 | 同簇混「太大」与「太小」 | 强制拆成正/反两个簇 |
| 可执行性 | 无法映射到产品参数 | 归 `other`，不进 Top 10 |
| 归因 | 把物流损坏算成产品质量 | 拆出 `packaging_damage`，单独统计 |
| 重复计数 | 同一用户在同一 ASIN 的 3 条评论算 3 次 | 去重到 1 次 |

## 5. 输出示例（真实量级）

| pain_point_id | cluster_label | mention_count | source_mix | sentiment | severity | improvable |
|---|---|---|---|---|---|---|
| PP-01 | leaks_at_lid_seal | 214 | review:168;qa:31;reddit:15 | −0.62 | 5 | 9 |
| PP-02 | hinge_cracks_in_3_months | 132 | review:96;reddit:24;tiktok:12 | −0.71 | 5 | 7 |
| PP-03 | too_small_for_standard_sink | 88 | review:61;qa:19;reddit:8 | −0.35 | 4 | 8 |
| PP-04 | hard_to_clean_corners | 76 | review:58;qa:12;tiktok:6 | −0.44 | 3 | 6 |
| PP-05 | overpriced_vs_alternatives | 64 | review:41;reddit:18;tiktok:5 | −0.28 | 3 | 2 |

注意 PP-05 频次不低但 `improvable_score=2`：只能靠定价或捆绑，不能当产品改进点。
