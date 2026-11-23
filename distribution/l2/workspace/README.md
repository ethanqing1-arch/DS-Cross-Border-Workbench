# 跨境电商工作区约定

这个目录是 DS-Bot 团队的共享工作区。所有 Bot 与群聊都按这里的规则读写文件，**不要自创目录结构**，否则下游的报告和脚本会找不到东西。

## 目录职责

| 目录 | 谁写 | 内容 |
|---|---|---|
| `00-inbox/` | 用户 | 原始资料投放区：供应商报价单、平台后台导出的 CSV、竞品截图、聊天记录。Bot 只读，不删 |
| `10-market/` | 情报官 | `competitors/` 竞品档案（一竞品一文件）、`keywords/` 关键词库、`trends/` 类目趋势、`candidates/` 候选卡与 `candidates/_scored/` 引擎产物 |
| `20-products/<SKU>/` | 各 Bot 分工写 | 一个 SKU 一个目录，子目录固定：`spec/ cost/ listing/ assets/ compliance/` |
| `30-suppliers/` | 采购官 | 供应商档案、询价记录、比价表 |
| `40-ads/` | 投放官 | 广告结构、否词库、ACOS 周报 |
| `50-service/` | 客服官 | `templates/` 多语言话术、`disputes/` 纠纷与差评处理记录 |
| `60-reports/` | 数据官 | `daily/ weekly/ monthly/`，文件名 `YYYY-MM-DD.md` |
| `70-compliance/` | 合规官 | `certificates/` 认证与到期日、`tax/` VAT/IOSS/EPR、`labels/` 标签与警示语 |
| `90-templates/` | 用户/Chief | 模板，只读。要改模板先问用户 |
| `95-engine/` | 情报官（只读执行） | 选品评分引擎：`score.py` 出分、`selftest.py` 自检、`vendor/` 带 openpyxl（别删）。用法见 `95-engine/README.md` |

## SKU 命名

`<站点>-<类目>-<三位序号>`，全大写，例：`US-KITCHEN-001`、`DE-PET-014`。
站点用 Amazon 市场代码（US / UK / DE / FR / IT / ES / JP / CA / MX / AU），非亚马逊渠道加前缀（`SHOPIFY-`、`TIKTOK-`）。

## 文件写入规则

1. **一个事实只存一处**。价格只在 `20-products/<SKU>/cost/pricing.csv` 里，别在报告里另存一份数字。
2. **改文件不新建版本**。不要 `xxx-v2.md`、`xxx-final.md`；历史靠 git 或 journal，不靠文件名。
3. **报告只写结论和数字**，不写过程叙事。过程留在群聊里。
4. **不写密钥**。API key、店铺密码、供应商账号一律不进工作区；要记就只记"在 1Password 里，条目名 XXX"。
5. 跨 Bot 交接用 `handoffs` 机制（群聊里 @ 对方），不要互相改对方的目录。

## 数字口径（所有 Bot 必须一致）

- 货币：成本用 CNY，售价用站点本币，换算汇率写在 `10-market/fx.md`，每周一更新。
- 毛利 = 售价 − 平台佣金 − 履约费 − 头程分摊 − 广告费 − 退货摊销 − 支付/汇损。
- 广告费按「实际花费 ÷ 实际销售额」算 ACOS，不用预估。
- 退货率用近 90 天滚动值，新 SKU 用同类目均值并在文件里标注 `[估算]`。

## 时间

所有定时任务按 `Asia/Shanghai` 触发；报告里的日期用站点当地时区并在标题注明，例：`2026-11-22 (US-Pacific)`。
