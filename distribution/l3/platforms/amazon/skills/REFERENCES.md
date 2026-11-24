# Amazon 专项 skill 来源与授权

- 来源绝对路径为 `/Users/xavier/Desktop/cbec-selection-master/skills/`。
- 抽取日期为 2026-11-23。
- 本包保留来源的 8 层目录，共 23 个 skill。每个 skill 的入口为 `<层>/<skill-name>/SKILL.md`，附属文件保留在原相对路径。
- 授权归属待定，对外分发前需确认。

## 随包的非 skill 文件

| 包内路径 | 来源 | 用途 |
|---|---|---|
| `engine/score.py` | `<源>/engine/score.py` | 选品打分引擎（四维打分 + 三层利润 + 硬红线） |
| `engine/selftest.py` | `<源>/engine/selftest.py` | 引擎自检，128 项断言 |
| `engine/validate_skills.py` | `<源>/engine/validate_skills.py` | 校验 23 个 skill 的结构与行数 |
| `data/candidates_sample.csv` | `<源>/data/candidates_sample.csv` | 12 行纯样例候选，引擎默认输入 |
| `SKILL_SPEC.md` | `<源>/SKILL_SPEC.md` | 23 个 skill 的写作规范，唯一事实源 |

完整性实测（2026-11-24）：源 `skills/` 下 46 个文件与本包逐文件 `cmp` 比对，
`OK=46 DIFF=0 MISSING=0`；`validate_skills.py` 报 `23 通过 / 0 有问题`。

`INSTALL.md` 不进包：它讲的是源目录 `~/Desktop/cbec-selection-master` 的装法，
路径与本包落点不同，直接随包会误导；引擎用法已改写进包 README。

## Skill 清单

| 层目录 | 数量 | Skill |
|---|---:|---|
| `00-router` | 1 | `cbec-command` |
| `01-data` | 4 | `amz-keyword-harvest`、`amz-listing-scrape`、`amz-review-harvest`、`web-trend-scan` |
| `02-market` | 3 | `market-entry`、`market-sizing`、`market-trend` |
| `03-demand` | 3 | `demand-priority`、`jtbd-map`、`voc-mining` |
| `04-competitor` | 4 | `competitor-deconstruct`、`negative-review-gap`、`pricing-ladder`、`visual-strategy` |
| `05-product` | 4 | `compliance-gate`、`decision-control`、`profit-model`、`supply-verify` |
| `06-delivery` | 2 | `deck-report`、`excel-report` |
| `07-system` | 2 | `skill-creator`、`toolchain-dispatch` |
