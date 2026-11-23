---
name: excel-report
description: Excel 多 sheet 交付：把选品结果落成总览/打分明细/利润瀑布/关键词/评论痛点/竞品对标 6 个 sheet，含列定义、红黄绿条件格式、冻结窗格与打印设置，并用 openpyxl 实现后回读校验行数。当用户提到「出 Excel」「做个表」「选品看板」「多 sheet」「条件格式」「导出 xlsx」时使用。
layer: 06-delivery
version: 1.0.0
inputs: [选品打分.csv, 利润瀑布.csv, 关键词.csv, 评论痛点.csv, 竞品对标.csv, run_id]
outputs: [选品看板.xlsx]
upstream: [decision-control, profit-model, market-trend, visual-strategy]
downstream: [deck-report]
---

# Excel 多 sheet 交付（6 表 + 条件格式 + 回读校验）

## 何时用

- `decision-control` 出了结论，需要一份能给团队传阅的表。
- 老板要"能自己点筛选看"的东西，不要截图。
- 多个候选品要横向比，需要一张总览 + 若干明细。
- 每期复盘要同结构重出，靠模板而不是重做。
- 数据要交给不装脚本的人，格式必须自解释。

不归这里：写汇报叙事与结论页 → `deck-report`；重新算利润 → `profit-model`（本 skill 只排版，不算数）。

## 输入契约

| 字段 | 来源 | 缺失时怎么办 |
|---|---|---|
| `选品打分.csv` | `decision-control` | **必需**，列名须与统一字典一致 |
| `利润瀑布.csv` | `profit-model` | **必需**（利润瀑布 sheet 唯一数据源） |
| `关键词.csv` | 上游关键词层 | 缺失则 sheet 保留表头 + 一行"本批未采集"，标 `[缺]` |
| `评论痛点.csv` | 上游评论分析 | 缺失同上处理 |
| `竞品对标.csv` | `competitor-deconstruct` | 缺失同上处理 |
| `run_id` | `YYYYMMDD-HH-MM-<category-slug>` | **必需**（写进文件名页脚与首页） |

不允许在本 skill 内改数：所有数值原样搬运，四舍五入只在单元格格式层做（`0.00` / `0.0%`）。

## 执行流程

1. **建工作簿**：`openpyxl.Workbook()`，按顺序建 6 个 sheet：`总览`、`打分明细`、`利润瀑布`、`关键词`、`评论痛点`、`竞品对标`；删掉默认 `Sheet`。
2. **总览 sheet**：第 1 行写标题（`<run_id> 选品总览`，合并 A1:N1），第 2 行表头，第 3 行起数据。列见 `references/sheets-columns.md` 第 1 节。
3. **打分明细 sheet**：每品一行，含四维分与总分、档位、红线标记；四维分单列，便于做红黄绿。
4. **利润瀑布 sheet**：每品一个区块（9 行 + 1 行空行），行序固定：售价/采购/头程/关税/毛利/平台佣金/FBA/推广/退货损耗/贡献利润。占比列用 `占比 = 行金额 / 售价`。
5. **关键词 sheet**：列 `keyword, search_volume, competition_level, cpc_usd, relevance, used_in_title`；按 `search_volume` 降序。
6. **评论痛点 sheet**：列 `pain_point, mention_count, share, severity, action`；按 `mention_count` 降序，只留 `mention_count ≥ 3` 的条。
7. **竞品对标 sheet**：列 `asin, brand, price_usd, review_count, rating, bsr, est_monthly_sales, top10_share, image_style, note`；按 `est_monthly_sales` 降序。
8. **加条件格式**：按第 4 节规则逐列加 `CellIsRule` / `FormulaRule`，红色 `FF0000`、黄色 `FFC000`、绿色 `00B050`，字体白/黑按对比度选。
9. **冻结与筛选**：每个 sheet `freeze_panes` 设到表头下方（总览 `A3`，其余 `A2`）；表头行加 `auto_filter.ref`。
10. **打印设置**：`orientation='landscape'`、`paperSize=A4`、`fitToWidth=1`、`print_title_rows='1:1'`（总览 `'1:2'`）、页脚写 `run_id + 生成日期`。
11. **保存**：`out/<run_id>/选品看板.xlsx`。
12. **回读校验**：`load_workbook(read_only=True)` 断言 6 个 sheet 名与顺序、每表 `max_row` 与源数据行数 + 表头行一致、关键列名逐字一致；断言失败直接报错，不出文件。

取数口径：行数断言 = `len(源数据) + 表头行数`；百分比列在源数据里是 0–1 小数，写入时保留原值、只改 `number_format`，不要在 Python 里乘 100。

### 实现要点（openpyxl，执行第 1–11 步的写法）

| 动作 | 写法要点 |
|---|---|
| 冻结 | `ws.freeze_panes = "A3"`（总览）/`"A2"` |
| 筛选 | `ws.auto_filter.ref = f"A2:{last_col}{last_row}"` |
| 条件格式 | `ws.conditional_formatting.add("J3:J40", CellIsRule(operator="greaterThanOrEqual", formula=["0.6"], fill=green))` |
| 文字匹配 | `FormulaRule(formula=['$K3="上架测试"'], fill=green)` |
| 数字格式 | `cell.number_format = "0.0%"` |
| 列宽 | `ws.column_dimensions["B"].width = 26` |
| 打印 | `ws.page_setup.orientation = "landscape"`、`ws.sheet_properties.pageSetUpPr.fitToPage = True`、`ws.page_setup.fitToWidth = 1` |
| 重复标题 | `ws.print_title_rows = "1:1"` |
| 页脚 | `ws.oddFooter.center.text = run_id` |
| 回读 | `wb2 = load_workbook(path, read_only=True)`；`assert wb2.sheetnames == [...]`；`assert ws2.max_row == n + 2` |

开源选型（不重复造轮子，按需替换）：`openpyxl`（MIT，读写 xlsx、条件格式支持最全）、`XlsxWriter`（BSD-2-Clause，写性能与图表更强，但只能新建不能改）、`pandas`（BSD-3-Clause，只用于读 CSV 与排序）。本 skill 默认 `openpyxl` + `pandas` 读源；要内嵌图表再评估 `XlsxWriter`。

## 判定口径

条件格式阈值（写死，改动要同步改本表）：

| sheet | 列 | 绿 | 黄 | 红 |
|---|---|---|---|---|
| 总览 | `verdict`（结论） | 上架测试 | 观察 | 放弃 |
| 总览 | `contribution_margin` | ≥ 20% | 8%–20% | < 8% |
| 总览 | `gross_margin` | ≥ 45% | 30%–45% | < 30% |
| 总览 | `redline_flags` | PASS | 单条 | ≥ 2 条 |
| 打分明细 | `score_total` | ≥ 60 | 48–59 | < 48 |
| 打分明细 | `score_demand` / `score_competition` / `score_profit` / `score_risk` | ≥ 60 | 40–59 | < 40 |
| 利润瀑布 | `贡献利润` 金额 | ≥ 3 USD | 0–3 USD | < 0 |
| 关键词 | `competition_level` | 低 | 中 | 高 |
| 评论痛点 | `severity` | 低 | 中 | 高 |
| 竞品对标 | `price_usd` | 在价格带内 | 超出 ±15% | 超出 ±30% |

打印与可读性：

| 项 | 值 |
|---|---|
| 纸张 | A4 横向 |
| 缩放 | 1 页宽，行不限 |
| 重复标题行 | 第 1 行（总览第 1–2 行） |
| 列宽 | 文本 18–28，数字 12–14 |
| 数字格式 | USD `#,##0.00`；百分比 `0.0%`；整数 `#,##0` |
| 网格线 | 关闭（`showGridLines = False`），靠边框分组 |

## 输出契约

- 落盘：`out/<run_id>/选品看板.xlsx`（6 sheet，顺序固定）
- 每个 sheet 的表头必须与 `references/sheets-columns.md` 逐字一致；统一字典字段（`sku`/`cogs_cny`/`price_usd`/`contribution_profit_usd`/`contribution_margin`/`score_total`/`verdict` 等）不得改名。
- 允许的扩展列：`rank, sku_tier, redline_flags, evidence_grade, note`。
- 正文格式：先给"文件已生成 + 6 个 sheet 各几行"的清单，再给"三处最该看的地方"（哪一行最红、哪个指标最差），最后给动作。

## 质检清单

- [ ] 6 个 sheet 名与顺序完全正确，无默认 `Sheet` 残留。
- [ ] 每个 sheet 表头与列定义逐字一致，统一字典字段没改名。
- [ ] `freeze_panes` 已设，滚动时表头不动。
- [ ] 条件格式覆盖第 4 节全部规则，颜色是真红黄绿不是主题色。
- [ ] 百分比列为 0–1 小数 + `0.0%` 格式，没有被乘过 100。
- [ ] 打印已设横向、1 页宽、重复标题行、页脚含 `run_id`。
- [ ] 回读断言通过：sheet 数 = 6、各表行数 = 源数据 + 表头、列名匹配。
- [ ] 数据可信度声明：首页某单元格写明 `证据等级分布 A/B/C/D = n1/n2/n3/n4，D 级占比 x%`。

## 反模式

- 把 6 张表堆在一个 sheet 里用空行分隔。→ 错：筛选会串行、冻结会失效；必须一表一 sheet。
- 条件格式用"色阶"渐变。→ 错：红黄绿必须是离散阈值，渐变看不出"是否破线"。
- 在 Python 里把 0.1244 写成 12.44 再套 `0.0%`。→ 错：会变成 1244.0%；保留小数原值只改格式。
- 生成完不校验就交付。→ 错：openpyxl 的 `max_row` 常因空行错位；必须回读断言行数。
- 每期手工调列宽与颜色。→ 错：把列宽、格式、条件格式写进同一个 `build_workbook()`，模板化。
