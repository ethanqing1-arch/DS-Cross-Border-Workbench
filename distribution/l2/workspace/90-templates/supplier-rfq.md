# 询价单（RFQ）

复制到 `30-suppliers/rfq/<SKU>-<供应商>-<日期>.md`，中英双语直发。**一次只问一个 SKU**，问得越具体报价越准。

---

## 中文版（1688 / 微信）

```
您好，我们做跨境电商（主要美国/欧洲站），在找长期供应商。请按下面几项报价：

1. 产品：        （附参考图/链接）
2. 材质与工艺：
3. 颜色：
4. 数量档位：    500 / 1000 / 3000 / 5000 件 分别报价
5. 包装：        OPP 袋 / 彩盒 / 定制logo，请分别给价
6. 单件毛重：    g        外箱尺寸：    cm   装箱数：   /箱
7. 打样费与周期：
8. 大货交期（确认订单后 N 天）：
9. 是否可定制：   logo/颜色/尺寸/包装
10. 认证：       是否已有 CE / FCC / RoHS / FDA（有请提供报告编号）
11. 付款方式：   （30% 定金 + 70% 见提单？）
12. 质保与次品率：承诺次品率 % ，超出如何处理
13. 发货地（省/市）与是否支持我司货代上门提货

另外请确认：
- 是否做过亚马逊 FBA，能否配合贴标（FNSKU）与外箱唛
- 旺季（9-12 月）产能是否稳定，会不会缺货
- 是否有同款在给其他跨境卖家供货（不用说是谁，只需说明有无）

麻烦报含税到厂价（13% 增值税专票）。谢谢。
```

## English (Alibaba / Made-in-China)

```
Hi, we are an Amazon/eBay cross-border seller (US & EU marketplaces) looking for a long-term supplier. Please quote:

1. Product: (reference image/link attached)
2. Material & process:
3. Colors available:
4. Quantity tiers: 500 / 1000 / 3000 / 5000 pcs — unit price for each
5. Packaging: poly bag / color box / custom logo — price per option
6. Unit gross weight: __ g; carton size: __ cm; pcs per carton: __
7. Sample cost & lead time:
8. Bulk lead time (after PO confirmation):
9. Customization: logo / color / size / packaging — yes or no
10. Certificates: CE / FCC / RoHS / FDA — report number if available
11. Payment terms:
12. Defect rate commitment and remedy policy
13. Factory location (province/city); can you support pickup by our forwarder?

Also please confirm:
- Have you supplied Amazon FBA sellers before? Can you apply FNSKU labels and carton marks?
- Is capacity stable during peak season (Sep–Dec)?
- Do you currently supply other cross-border sellers with this model?

Please quote FOB or ex-works with VAT invoice included. Thanks.
```

---

## 收到报价后的处理

1. 填 `30-suppliers/compare.csv`（列：供应商/单价/MOQ/交期/认证/次品率/付款/评分）
2. 至少 3 家，否则不算"比过价"，采购官不得推荐
3. 打样：只对评分前 2 名打样，样品费记入 `20-products/<SKU>/cost/samples.md`
4. 样品到手后 48 小时内出《样品评估》（重量实测、做工、包装、与描述差异）
