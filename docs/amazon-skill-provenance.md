# Amazon 23 个 skill 来源证据强度

本表补充 [Amazon 23 个 skill 授权归属核查](amazon-skill-licenses.md)，以分层目录和 bundle 各 23 个入口为核查范围。沿每个入口的 Git 路径历史查首次加入，再用首入库和首次打包提交的重命名、复制检测核对。下表中的日期为提交日期（北京时间）。

## 共有的仓库证据

- 首次入库提交 `97021cb` 把 23 个入口记为新增（`A`），重命名和复制检测均未找到本仓旧路径。同一次提交的 `skills/REFERENCES.md` 记录了从本机 `cbec-selection-master/skills/` 抽取、保留原层级和附属文件相对路径。表中「记录来源」由该提交的层级与目录名还原。
- 随后的 `8bc8b43` 为每个入口新增 `bundle/skills/<skill>/SKILL.md`。对该次提交启用复制检测得到 23 条从分层目录到 bundle 的 `C100`，原入口仍在。现有两处的目录内容逐项比对一致，共 23 个入口和 23 个附属文件。
- `02a6ef4` 补录了源目录与包内分层目录的全量比对（`OK=46 DIFF=0 MISSING=0`）。这条比对引用该提交的记录。本次核查逐项比对的是现有两份入库副本。提交者字段提供入库线索，附件中仍未见原作者署名、上游仓库地址或许可声明。[包内来源记录](../distribution/l3/platforms/amazon/skills/REFERENCES.md)

## 档位口径

- **明确出处**指有可追溯到作者或具体来源的记录。这里的证据追溯到抽取前的本机目录，并有入库时的路径记录和后续比对记录。原作者和该目录的更早来源待补证据。
- **只能追到本仓某次提交**指能定位提交，已查记录中缺少具体来源。
- **完全无迹**指已查 Git 历史也无法定位首次入库提交。

## 逐项核查

「记录来源」以 `cbec-selection-master/skills/` 为根。所有行的首入库状态均为 `A`，来自该本机目录的抽取由同提交文档记录。附件名以各 skill 目录为根。

| Skill | 首次入库提交及日期 | 记录来源目录 | SKILL.md 之外的文件与线索 | 证据强度 |
|---|---|---|---|---|
| `cbec-command` | `97021cb` · 2026-11-23 | `00-router/cbec-command/` | 无附属文件 | 明确出处 |
| `amz-keyword-harvest` | `97021cb` · 2026-11-23 | `01-data/amz-keyword-harvest/` | `references/keyword-tier-rules.md`，未见归属线索 | 明确出处 |
| `amz-listing-scrape` | `97021cb` · 2026-11-23 | `01-data/amz-listing-scrape/` | `references/field-mapping.md`，未见归属线索 | 明确出处 |
| `amz-review-harvest` | `97021cb` · 2026-11-23 | `01-data/amz-review-harvest/` | `references/spam-rules.md`，未见归属线索 | 明确出处 |
| `web-trend-scan` | `97021cb` · 2026-11-23 | `01-data/web-trend-scan/` | `references/source-playbook.md` 记载业务数据入口，未见归属线索 | 明确出处 |
| `market-entry` | `97021cb` · 2026-11-23 | `02-market/market-entry/` | `references/entry-scorecard.md`，未见归属线索 | 明确出处 |
| `market-sizing` | `97021cb` · 2026-11-23 | `02-market/market-sizing/` | `references/bsr-sales-table.md` 记载抽样和交叉校准的数据来源，未见归属线索 | 明确出处 |
| `market-trend` | `97021cb` · 2026-11-23 | `02-market/market-trend/` | `references/season-plan.md`，未见归属线索 | 明确出处 |
| `demand-priority` | `97021cb` · 2026-11-23 | `03-demand/demand-priority/` | `references/kano-scoring.md`，未见归属线索 | 明确出处 |
| `jtbd-map` | `97021cb` · 2026-11-23 | `03-demand/jtbd-map/` | `references/scenario-card-template.md`，未见归属线索 | 明确出处 |
| `voc-mining` | `97021cb` · 2026-11-23 | `03-demand/voc-mining/` | `references/cluster-taxonomy.md`，未见归属线索 | 明确出处 |
| `competitor-deconstruct` | `97021cb` · 2026-11-23 | `04-competitor/competitor-deconstruct/` | `references/claim-buckets.md`，未见归属线索 | 明确出处 |
| `negative-review-gap` | `97021cb` · 2026-11-23 | `04-competitor/negative-review-gap/` | `references/failure-modes.md`，未见归属线索 | 明确出处 |
| `pricing-ladder` | `97021cb` · 2026-11-23 | `04-competitor/pricing-ladder/` | `references/price-test-matrix.md`，未见归属线索 | 明确出处 |
| `visual-strategy` | `97021cb` · 2026-11-23 | `04-competitor/visual-strategy/` | `references/main-image-brief.md`，未见归属线索 | 明确出处 |
| `compliance-gate` | `97021cb` · 2026-11-23 | `05-product/compliance-gate/` | `references/compliance-matrix.md` 包含业务版权检查步骤，未见归属线索 | 明确出处 |
| `decision-control` | `97021cb` · 2026-11-23 | `05-product/decision-control/` | `references/scoring-and-card.md`，未见归属线索 | 明确出处 |
| `profit-model` | `97021cb` · 2026-11-23 | `05-product/profit-model/` | `references/fba-fees.md` 记载费率核对依据，`references/formula.md` 标注公式取自 [SKILL_SPEC.md](../distribution/l3/platforms/amazon/SKILL_SPEC.md) 第 4.1 节。未见原作者署名或许可声明 | 明确出处 |
| `supply-verify` | `97021cb` · 2026-11-23 | `05-product/supply-verify/` | `references/supplier-scorecard.md`，未见归属线索 | 明确出处 |
| `deck-report` | `97021cb` · 2026-11-23 | `06-delivery/deck-report/` | `references/slide-skeleton.md`，未见归属线索 | 明确出处 |
| `excel-report` | `97021cb` · 2026-11-23 | `06-delivery/excel-report/` | `references/sheets-columns.md`，未见归属线索 | 明确出处 |
| `skill-creator` | `97021cb` · 2026-11-23 | `07-system/skill-creator/` | `references/admission-gate.md`，未见归属线索 | 明确出处 |
| `toolchain-dispatch` | `97021cb` · 2026-11-23 | `07-system/toolchain-dispatch/` | `references/capability-matrix.md`，未见归属线索 | 明确出处 |

## 汇总

| 档位 | 数量 |
|---|---:|
| 明确出处 | 23 |
| 只能追到本仓某次提交 | 0 |
| 完全无迹 | 0 |

可复查首次提交和复制记录的命令（在仓库根目录执行）

```bash
git log --all --follow --diff-filter=ACR --format='%h %cs' -- distribution/l3/platforms/amazon/skills/00-router/cbec-command/SKILL.md
git diff --name-status -M -C --find-copies-harder 97021cb^ 97021cb
git show 97021cb:distribution/l3/platforms/amazon/skills/REFERENCES.md
git diff --name-status -M -C --find-copies-harder 8bc8b43^ 8bc8b43
git show 02a6ef4 -- distribution/l3/platforms/amazon/skills/REFERENCES.md
```
