# Amazon skill 分层

DSH 从 `skills/<skill-name>/SKILL.md` 发现 skill。工作区安装使用下列原始层目录。

| 原始层目录 | Skill |
|---|---|
| `00-router` | `cbec-command` |
| `01-data` | `amz-keyword-harvest`、`amz-listing-scrape`、`amz-review-harvest`、`web-trend-scan` |
| `02-market` | `market-entry`、`market-sizing`、`market-trend` |
| `03-demand` | `demand-priority`、`jtbd-map`、`voc-mining` |
| `04-competitor` | `competitor-deconstruct`、`negative-review-gap`、`pricing-ladder`、`visual-strategy` |
| `05-product` | `compliance-gate`、`decision-control`、`profit-model`、`supply-verify` |
| `06-delivery` | `deck-report`、`excel-report` |
| `07-system` | `skill-creator`、`toolchain-dispatch` |
