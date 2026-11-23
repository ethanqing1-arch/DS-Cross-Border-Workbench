# 关键词分层细则与合并规则

供 `amz-keyword-harvest` 步骤 6、8 直接执行。词典命中用「包含即命中」，词边界按空格切分。

## 1. 属性词典（命中即属性词）

| 类别 | 词条（小写） |
|---|---|
| 材质 | stainless steel, silicone, bamboo, wooden, ceramic, glass, plastic, abs, aluminum, titanium, leather, cotton, linen, polyester, nylon, memory foam |
| 尺寸 | mini, small, large, xl, oversized, compact, portable, slim, wide, tall, inch, cm, ft, oz, ml, l, gallon, qt |
| 颜色 | black, white, silver, gold, rose gold, gray, grey, beige, navy, pink, green, blue, red, clear, transparent, matte |
| 容量/功率 | 2 pack, 4 pack, 6 pack, 10 pack, set of, 12v, 24v, 110v, 220v, 5w, 10w, 20w, 60w, 100w, 5000mah, 10000mah |
| 结构/功能 | adjustable, foldable, collapsible, stackable, rechargeable, cordless, wireless, waterproof, dishwasher safe, non slip, heavy duty, magnetic, detachable, rotating, locking |
| 数量/规格 | pair, 2 in 1, 3 in 1, multipack, refill, replacement, compatible with |

## 2. 场景 / 人群词典（命中即场景词）

| 类别 | 词条 |
|---|---|
| 人群 | for kids, for toddlers, for baby, for women, for men, for seniors, for pets, for dogs, for cats, for nurses, for teachers |
| 空间 | for small apartment, for rv, for car, for desk, for kitchen, for bathroom, for bedroom, for garage, for camping, for travel |
| 时间/节日 | christmas, halloween, thanksgiving, valentines, easter, birthday, back to school, summer, winter, 2025, 2026 |
| 用途 | gift for, housewarming, wedding, office use, gym, yoga, hiking, fishing, gardening |

## 3. 品牌词典（命中即剔除，单独出表）

维护 `brand_terms.csv`：类目内 Top 50 品牌名 + 变体拼写。判定辅助：
- 词首大写出现在 ≥3 个 listing 标题同一位置；
- ABA 报告中该词点击份额 >60% 集中在 ≤3 个 ASIN；
- 含 `®`/`™`/`official`/`genuine`。
以上任一命中 → 品牌词，不进主词、不进标题。

## 4. 合并规则（顺序执行，不可跳）

1. 转小写、去 `,./'"!?()`、多空格压成一个、去首尾空格。
2. `&` → `and`；`w/` → `with`；`w/o` → `without`。
3. 单复数：`-ies`→`-y`；`-ses/-xes/-ches/-shes`→去 `es`；其余 `-s`→去 `s`（`ss` 结尾不动）。
4. 同义合并（保留左值作主词）：`wireless`=`cordless`；`non slip`=`anti slip`=`non-slip`；`for women`=`womens`；`kids`=`children`；`bag`=`pouch`（仅同品类内）。
5. 词序归一：`for kids silicone mat` 与 `silicone mat for kids` 合并为高频词序那条，记 `merged_from` 计数。
6. 剔除：长度 <3 字符、纯数字、`^b0[a-z0-9]{8}$`、含 `cheap`/`free shipping`/`amazon`。

## 5. 分层判定优先级

一词只归一层，按序判定，命中即停：

1. 品牌词 → 出表（不参与分层）。
2. 核心词：词数 ≤3 且 `monthly_search_volume` ≥50000 且 `relevance_ratio` ≥0.80。
3. 场景词：命中场景/人群词典，且 `monthly_search_volume` ≥800。
4. 属性词：命中属性词典，词数 ≤5。
5. 长尾词：词数 ≥4 且 `monthly_search_volume` 500–20000。
6. 其余 → `unclassified`，仅存档，不进标题、不进广告。

冲突处理：核心词同时命中场景词典时，归核心词，`secondary_tier=场景词`。属性词与长尾词同时命中时归属性词。

## 6. 采集工具栈（可直接复用，勿自研）

| 环节 | 工具 | 复用级别 | 落到本 skill 哪步 |
|---|---|---|---|
| 下拉词 | 直接 HTTP GET `completion.amazon.com/api/2017/suggestions`（公开接口，无需三方库） | 直接用 | 步骤 2 |
| ABA 报表 | 品牌后台手动导出 CSV（无公开 API），脚本只做清洗 | 清洗自写 | 步骤 3 |
| 反查流量词 | Helium10 Cerebro / 卖家精灵 导出 CSV；开源替代 `praw`+`pytrends` 只能补站外 | 外部导出 | 步骤 4 |
| 页面解析 | `playwright`（`microsoft/playwright-python`，Apache-2.0）+ `selectolax`（MIT） | 直接用 | 步骤 7、9 |
| 代理 | `proxy_pool` 类自建池或商业住宅代理 | 直接用 | 全部请求 |

原则：能用官方导出就不用爬；能爬前台就不碰后台；请求间隔 ≥1.5s，单 IP 每小时 ≤300 次。

## 7. 量级换算参考（仅用于校验，不作主口径）

ABA 周排名 → 周搜索量粗估（美国站，全类目混合，误差 ±40%）：

| 排名区间 | 周搜索量粗估 |
|---|---|
| 1–100 | 80,000–400,000 |
| 101–1,000 | 18,000–80,000 |
| 1,001–10,000 | 3,500–18,000 |
| 10,001–50,000 | 900–3,500 |
| 50,001–300,000 | 120–900 |

用法：只在上游无搜索量列时做幂律拟合的锚点，拟合结果标 C；与第三方工具差值 >2 倍时以第三方为准并标注来源。
