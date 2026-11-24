# 交接单 19：关键词粗筛报告（两条已通数据源的第一次合流）

日期：2026-11-24
上游：交接单 18（`423154c`，AliExpress 接入）

## 这单要解决什么

现在有两条免费真实数据源——Amazon 美国站前台（`fetch_amazon.py`）和 AliExpress 美国区（`fetch_aliexpress.py`）——但没有任何东西把它们合成一个能看的结论。人要看一个关键词值不值得做，得自己跑两个脚本再心算。

这单做一个**粗筛报告**：给一个关键词，输出一份 md + csv。

**它不出决策。** 不打分、不写「上架测试 / 小范围观察 / 放弃」——那是 `score_products.py` 的事，而它现在因为缺 5 列只能输出「补数据」。粗筛只把**现在真能拿到的数**摊开给人看。

## 数据源与边界

只用这两个脚本的输出，**不改它们**：

- `distribution/l2/skills/market-research/scripts/fetch_amazon.py`：`search`（ASIN/标题/价/评分/评论数/是否广告/总结果数/广告密度）+ `product`（BSR/五点/`date_first_available`/`sold_by`/`ships_from`/`fulfillment`）
- `distribution/l2/skills/market-research/scripts/fetch_aliexpress.py`：`sale_price_usd` / `discount_pct` / `sold_count`

**不做的事**：不做 USD→CNY 换算；不碰 `score_products.py`；不把 AliExpress 零售价当 `1688进价`。

## T1 新增 `screen_keyword.py`

位置：`distribution/l2/skills/market-research/scripts/screen_keyword.py`（同步到 `distribution/l2/bundle/skills/market-research/scripts/`，`distribution/l2/install.sh:189` 有 `diff -qr` 校验）。

python 3.9.6，只用标准库。两种模式：

1. **在线**：`screen_keyword.py "pet slow feeder" --top 20`
   调上面两个脚本（子进程），串行，两次调用间隔 ≥2 秒，`--top` 上限 20。
2. **离线**：`screen_keyword.py "pet slow feeder" --from-json <dir>`
   从目录读已保存的 JSON（`amazon_search.json` / `amazon_products.json` / `aliexpress_search.json`），不联网。回归用这个。

## T2 指标口径（逐条写死，不许自创）

**A. 需求侧（Amazon 搜索页）**

| 指标 | 口径 |
|---|---|
| `搜索结果总数` | `total_results_text` 原文 + 解析后的整数（如 `5,000` → 5000）；解析不出给原文 + `null` |
| `广告密度` | `sponsored_count / count`，保留三位小数 |
| `评论数中位数` | Top N 的 `reviews` 中位数（`reviews` 是带逗号的字符串，先转整数） |
| `评论数最大` | Top N 最大值 |
| `评论数>1000占比` | 计数 / N |
| `评分中位数` | Top N 的 `rating` 中位数 |
| `价格带` | Top N 的 `price`（`$X.XX` → float）：min / P25 / 中位 / P75 / max |

**B. 进入难度（Amazon 商品页，逐 ASIN 抓 Top N，串行 ≥2 秒）**

| 指标 | 口径 |
|---|---|
| `上架月龄中位数` | `date_first_available`（如 `July 13, 2023`）→ 距今天数 / 30.44，四舍五入到 1 位小数；解析不出计入 `unknown` |
| `新品占比(<12个月)` | 上架月龄 <12 的计数 / 能解析出月龄的样本数（分母不是 N，报告里要写清） |
| `FBA占比` | `fulfillment == "fba"` / N；同时给出 `fbm` 与 `unknown` 计数 |
| `卖家数` | Top N 里 `sold_by` 去重数（`null` 不计入，但要在报告里写「有效样本 M/N」） |

**C. 货源侧（AliExpress 搜索页）**

| 指标 | 口径 |
|---|---|
| `货源价中位数` | `sale_price_usd` 中位数（`null` 剔除，报告写有效样本数） |
| `货源折扣中位数` | `discount_pct` 中位数 |
| `货源销量中位数` | `sold_count` 中位数（`null` 剔除） |
| `零货倍数` | `Amazon 价格中位 / 货源价中位`，保留一位小数；任一为 `null` 或 0 → `NA` |

## T3 输出

`--out <dir>`（默认 `out/`），两份文件：

1. `<keyword>-粗筛.md`，结构固定：
   - 标题（关键词、生成时间、样本量 N）
   - `## 需求侧` / `## 进入难度` / `## 货源侧`：每个指标一行，格式 `指标 | 值 | 样本量 | 来源`，算不出的写 `NA（原因）`
   - `## 缺口`：固定列出抓不到的 5 列（`1688进价`、`运费`、`平均退货率`、`月搜索量`、`在售竞品数`）并注明「这些不在本报告范围内，打分表会据此输出『补数据』」
   - `## 数据可信度`：采集时间、各源返回状态（http / currency_verified）、降级原因原文
2. `<keyword>-粗筛.csv`，列：`指标,值,样本量,来源,证据等级,备注`
   - `来源` ∈ `amazon` / `aliexpress`；`证据等级` 一律 `B`（前台抓取），算不出的行等级写 `D`

**报告里任何指标拿不到就写 `NA` 并说明原因，不许填 0、不许估算、不许用别的字段凑。**

## T4 回归（离线，不联网）

1. 用这次真实抓取的结果，把三个 JSON 存成 fixture，放 `distribution/l2/skills/market-research/scripts/fixtures/screen/`（体积越小越好，可裁剪到 Top 5）。
2. `verify.sh` 增加一节 `7d. 粗筛报告口径`，断言：
   - 离线模式跑通、退出码 0；
   - md 里 `## 需求侧`、`## 进入难度`、`## 货源侧`、`## 缺口`、`## 数据可信度` 五节齐全；
   - csv 的行数与指标清单一致，且**不出现** `上架测试` / `小批量观察` / `放弃` 任一决策词（证明它没有越权出决策）；
   - 故意删掉 fixture 里 `amazon_products.json` 再跑一次，`上架月龄中位数` 必须变成 `NA` 而不是 0。

## 验收（你自己跑，贴原文）

```bash
# 1. 在线真实跑（贴完整 md）
python3 distribution/l2/skills/market-research/scripts/screen_keyword.py "pet slow feeder" --top 10 --out /tmp/screen-online

# 2. 离线回归
python3 distribution/l2/skills/market-research/scripts/screen_keyword.py "pet slow feeder" --from-json distribution/l2/skills/market-research/scripts/fixtures/screen --out /tmp/screen-offline

# 3. 缺 fixture 时必须 NA 不是 0（贴原文）

# 4. 全量验收
bash distribution/verify.sh
bash distribution/flow-smoke.sh

# 5. 镜像零 drift
diff -qr distribution/l2/skills distribution/l2/bundle/skills
```

## 边界

- 不碰 `farm/`、台账、`~/.dsh`、DS Bot 自身、系统设置、launchd。
- **不改** `fetch_amazon.py`、`fetch_aliexpress.py`、`score_products.py`——只调用前两个。
- 不写真实凭证；不加需要花钱的依赖；不登录任何站点。
- **不许编数字**：拿不到就 `NA`。
- 抓取礼貌：单次间隔 ≥2 秒，`--top` 上限 20，一次运行最多抓 20 个商品页。
- 报告**不许出现**「上架测试 / 小批量观察 / 放弃」这类决策词，粗筛只摊数据。
- 完成后不要 git commit、不要 git push，改完停在工作区等验收；把验收原文追加到本单末尾的 `## 收尾` 一节。
