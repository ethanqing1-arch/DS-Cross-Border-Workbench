# 上架简报（Listing Brief）

由 Listing 官写，存 `20-products/<SKU>/listing/brief.md`；写手与设计只认这份文件，不再口头传话。

```yaml
sku: US-KITCHEN-001
site: US
locale: en-US
target_price: 29.99
main_keyword: collapsible dish drying rack
secondary_keywords: [over sink drainer, silicone dish rack, folding dish rack]
brand: (自有品牌名)
status: draft        # draft | review | live
```

## 1. 卖点排序（最多 5 条，按转化贡献排序）

| # | 卖点（中文意图） | 英文表达（可直接用） | 证据/来源 |
|---|---|---|---|
| 1 | 折叠省空间 | Folds flat to 1.2 in — fits in a drawer | 产品实测 |
| 2 | 承重不塌 | Holds 22 lb of wet dishes without bending | 供应商数据 |
| 3 | 不发霉易清洗 | Silicone-coated steel, dishwasher safe | 材质报告 |

## 2. 标题（≤ 200 字符，美国站）

规则：品牌 + 核心关键词 + 3 个差异点 + 规格/数量 + 适用场景。不堆词、不全大写、不含促销语。

```
[草稿]
```

## 3. 五点描述（Bullet Points）

每条 ≤ 220 字符，首句大写短语 + 利益点，第二句给证据。

```
1.
2.
3.
4.
5.
```

## 4. 搜索词（后台 Search Terms，≤ 250 字节）

只用标题和五点里没出现过的词；不重复品牌；不写竞品品牌。

```
```

## 5. A+ / 图片 Brief

| 位次 | 内容 | 必须传达 | 素材要求 |
|---|---|---|---|
| 主图 | 白底 85% 占幅 | 形态与尺寸感 | 2000×2000，无文字 |
| 图 2 | 折叠前后对比 | 省空间 | 同上，含尺寸标注 |
| 图 3 | 承重实测 | 不塌 | 场景图，真人手部 |
| 图 4 | 场景（厨房水槽旁） | 适用场景 | 生活场景，避免过度精修 |
| 图 5 | 细节（硅胶包边、脚垫） | 做工 | 微距 |
| 图 6 | 包装与清单 | 收到什么 | 平铺 |
| A+ | 模块 1 品牌故事 / 模块 2 对比表 / 模块 3 使用步骤 | 差异化 | ≤ 3 个模块起 |

## 6. 本地化注意

- 英式/德式拼写差异（-ize/-ise、color/colour）按站点切换
- 德语复合词拆解、日语敬体
- 单位：美国用 inch/lb，欧洲用 cm/kg
- 禁用词：best seller、#1、FDA approved（无证不得写）

## 7. 上架前检查（勾选才算 review 通过）

- [ ] 标题无关键词堆砌、无全大写、无促销语
- [ ] 五点每条都有证据支撑
- [ ] 主图纯白底、无水印文字
- [ ] 变体关系（尺寸/颜色）已定
- [ ] 合规标签与警示语已由合规官签字
- [ ] 价格与 `cost/pricing.csv` 一致
