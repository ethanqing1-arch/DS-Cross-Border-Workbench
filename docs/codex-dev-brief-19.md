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

## 收尾

### 1. 在线实抓

```bash
python3 distribution/l2/skills/market-research/scripts/screen_keyword.py "pet slow feeder" --top 10 --out /tmp/screen-online
```

```text
Markdown 写入 /tmp/screen-online/pet slow feeder-粗筛.md
CSV 写入 /tmp/screen-online/pet slow feeder-粗筛.csv
```

首轮 Amazon 与 AliExpress 各返回 10 个搜索样本。Amazon 商品页这轮没有可解析月龄。首轮完整 Markdown 如下。

```text
# pet slow feeder 粗筛

生成时间 2026-11-24T22:10:07+08:00｜样本量 N=10（Amazon 搜索 Top 10）

## 需求侧

| 指标 | 值 | 样本量 | 来源 |
| --- | --- | --- | --- |
| 搜索结果总数 | 5000（原文：5,000） | 1 页 | amazon |
| 广告密度 | 0.100（sponsored_count / count = 1/10） | 10 | amazon |
| 评论数中位数 | 11726.5 | 10/10 | amazon |
| 评论数最大 | 135893 | 10/10 | amazon |
| 评论数>1000占比 | 0.9 | 10/10 | amazon |
| 评分中位数 | 4.6 | 10/10 | amazon |
| 价格带 | min $6.39 / P25 $7.4625 / 中位 $7.81 / P75 $12.8 / max $39.99 | 10/10 | amazon |

## 进入难度

| 指标 | 值 | 样本量 | 来源 |
| --- | --- | --- | --- |
| 上架月龄中位数 | NA（date_first_available 无有效月龄；unknown=10） | 0/10 | amazon |
| 新品占比(<12个月) | NA（date_first_available 无有效月龄；分母为能解析出月龄的样本数） | 0 | amazon |
| FBA占比 | NA（fulfillment 无有效发货方式；fba=0，fbm=0，unknown=10） | 10 | amazon |
| 卖家数 | NA（sold_by 无有效卖家；有效样本 0/10） | 0/10 | amazon |

## 货源侧

| 指标 | 值 | 样本量 | 来源 |
| --- | --- | --- | --- |
| 货源价中位数 | 4.08（USD） | 9/10 | aliexpress |
| 货源折扣中位数 | NA（discount_pct 缺失或无法解析） | 9/10 | aliexpress |
| 货源销量中位数 | 31 | 9/10 | aliexpress |
| 零货倍数 | 1.9（Amazon 价格中位数 / AliExpress 货源价中位数） | Amazon 10/10；AliExpress 9/10 | aliexpress |

## 缺口

1688进价、运费、平均退货率、月搜索量、在售竞品数。这些不在本报告范围内，打分表会据此输出『补数据』。

## 数据可信度

模式：在线采集。B 为前台抓取证据，D 为指标不可得。
零货倍数使用 Amazon 搜索价与 AliExpress 美元零售价。
- Amazon 搜索页｜采集时间 2026-11-24T22:08:23+08:00｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"degraded": null}
- AliExpress 搜索页｜采集时间 2026-11-24T22:08:27+08:00｜http=200｜currency_verified=true｜退出码=0｜降级原因原文 {"degraded": ["sale_price_usd", "original_price_usd", "discount_pct", "sold_text", "sold_count", "rating"]}
- Amazon 商品页 B0C5HSCS8J｜采集时间 2026-11-24T22:08:37+08:00｜http=503｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "http_503", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B084RZ1B25｜采集时间 2026-11-24T22:08:42+08:00｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B00L3O4JI6｜采集时间 2026-11-24T22:08:53+08:00｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "blocked_by_amazon", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B0D7CC26QL｜采集时间 2026-11-24T22:09:04+08:00｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "blocked_by_amazon", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B0BWDY948D｜采集时间 2026-11-24T22:09:14+08:00｜http=503｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "http_503", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B00L3O3UPE｜采集时间 2026-11-24T22:09:24+08:00｜http=503｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "http_503", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B0965CYRT1｜采集时间 2026-11-24T22:09:35+08:00｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "blocked_by_amazon", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B09LD2CD1L｜采集时间 2026-11-24T22:09:45+08:00｜http=503｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "http_503", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B0787FVCBW｜采集时间 2026-11-24T22:09:57+08:00｜http=503｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "http_503", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
- Amazon 商品页 B0FK1WY1LB｜采集时间 2026-11-24T22:10:07+08:00｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "blocked_by_amazon", "degraded": ["date_first_available", "sold_by", "ships_from", "rating_histogram", "customers_say", "review_text"]}
```

最终代码复跑时 Amazon 搜索返回 HTTP 503，AliExpress 返回 HTTP 200 且美元校验通过。复跑完整 Markdown 如下。

```text
# pet slow feeder 粗筛

生成时间 2026-11-24T22:18:12+08:00｜样本量 N=0（Amazon 搜索 Top 10）

## 需求侧

| 指标 | 值 | 样本量 | 来源 |
| --- | --- | --- | --- |
| 搜索结果总数 | NA（http_503；原文：null；解析：null） | 0 页 | amazon |
| 广告密度 | NA（http_503） | NA | amazon |
| 评论数中位数 | NA（http_503） | 0/0 | amazon |
| 评论数最大 | NA（http_503） | 0/0 | amazon |
| 评论数>1000占比 | NA（http_503） | 0/0 | amazon |
| 评分中位数 | NA（http_503） | 0/0 | amazon |
| 价格带 | NA（http_503） | 0/0 | amazon |

## 进入难度

| 指标 | 值 | 样本量 | 来源 |
| --- | --- | --- | --- |
| 上架月龄中位数 | NA（无 Amazon 搜索样本；unknown=0） | 0/0 | amazon |
| 新品占比(<12个月) | NA（无 Amazon 搜索样本；分母为能解析出月龄的样本数） | 0 | amazon |
| FBA占比 | NA（无 Amazon 搜索样本；fba=0，fbm=0，unknown=0） | 0 | amazon |
| 卖家数 | NA（无 Amazon 搜索样本；有效样本 0/0） | 0/0 | amazon |

## 货源侧

| 指标 | 值 | 样本量 | 来源 |
| --- | --- | --- | --- |
| 货源价中位数 | 3.43（USD；有效样本 9/10） | 9/10 | aliexpress |
| 货源折扣中位数 | NA（discount_pct 缺失或无法解析） | 9/10 | aliexpress |
| 货源销量中位数 | 33.5（有效样本 8/10） | 8/10 | aliexpress |
| 零货倍数 | NA（Amazon 价格中位数缺失或为 0） | Amazon 0/0；AliExpress 9/10 | aliexpress |

## 缺口

1688进价、运费、平均退货率、月搜索量、在售竞品数。这些不在本报告范围内，打分表会据此输出『补数据』。

## 数据可信度

模式：在线采集。B 为前台抓取证据，D 为指标不可得。
零货倍数使用 Amazon 搜索价与 AliExpress 美元零售价。
- Amazon 搜索页｜采集时间 2026-11-24T22:18:07+08:00｜http=503｜currency_verified=NA（未返回）｜退出码=0｜降级原因原文 {"error": "http_503", "degraded": true}
- AliExpress 搜索页｜采集时间 2026-11-24T22:18:12+08:00｜http=200｜currency_verified=true｜退出码=0｜降级原因原文 {"degraded": ["sale_price_usd", "original_price_usd", "discount_pct", "sold_text", "sold_count", "rating"]}
- Amazon 商品页｜采集时间 NA（未保存采集时间）｜http=NA（未返回）｜currency_verified=NA（未返回）｜退出码=NA（未保存）｜降级原因原文 {"error": "无商品页记录"}
```

### 2. 离线回归

三个 fixture 来自同一轮 Top 5 实抓。AliExpress 返回 5 条通过美元校验的样本。Amazon 搜索返回 HTTP 503，商品页文件保存了该轮空列表。

```bash
python3 distribution/l2/skills/market-research/scripts/screen_keyword.py "pet slow feeder" --from-json distribution/l2/skills/market-research/scripts/fixtures/screen --out /tmp/screen-offline
```

```text
Markdown 写入 /tmp/screen-offline/pet slow feeder-粗筛.md
CSV 写入 /tmp/screen-offline/pet slow feeder-粗筛.csv
```

### 3. 缺商品页 fixture 的负例

```bash
screen_missing="$(mktemp -d /tmp/screen-missing.XXXXXX)" || exit 1
cp -R distribution/l2/skills/market-research/scripts/fixtures/screen "$screen_missing/fixture" || exit 1
rm "$screen_missing/fixture/amazon_products.json" || exit 1
python3 distribution/l2/skills/market-research/scripts/screen_keyword.py "pet slow feeder" --from-json "$screen_missing/fixture" --out "$screen_missing/out" || exit 1
rg -F '上架月龄中位数' "$screen_missing/out/pet slow feeder-粗筛.md" "$screen_missing/out/pet slow feeder-粗筛.csv"
```

```text
Markdown 写入 /tmp/screen-missing.R9BBNU/out/pet slow feeder-粗筛.md
CSV 写入 /tmp/screen-missing.R9BBNU/out/pet slow feeder-粗筛.csv
/tmp/screen-missing.R9BBNU/out/pet slow feeder-粗筛.csv:上架月龄中位数,NA,0/0,amazon,D,缺少 amazon_products.json；unknown=0
/tmp/screen-missing.R9BBNU/out/pet slow feeder-粗筛.md:| 上架月龄中位数 | NA（缺少 amazon_products.json；unknown=0） | 0/0 | amazon |
```

独立正样本使用临时构造的单 ASIN 输入，验证删文件前后的数值切换。两个变异均在临时副本运行 7d，分别把缺失月龄回填为 0 和往 Markdown 插入决策词。

```text
PASS 独立正样本删文件实测：22.3 [B] → NA [D]
missing_age_to_zerorc=1
FAIL 删掉 amazon_products.json 后，上架月龄中位数校验失败
    缺少商品页时月龄未标为 NA 并附缺失原因：{'指标': '上架月龄中位数', '值': '0', '样本量': '0/0', '来源': 'amazon', '证据等级': 'B', '备注': '缺少 amazon_products.json；unknown=0'}
injected_decisionrc=1
FAIL 粗筛 CSV 或决策词校验失败
    pet slow feeder-粗筛.md 含决策词
```

### 4. 全量验收

```bash
bash distribution/verify.sh
```

```text
== kualang 三层总装验收 ==
仓库：/Users/xavier/Projects/DS-Cross-Border-Workbench
临时根目录：/tmp/kualang-verify.BuIhSs
-- 0. 入口文件
  PASS 存在 l1/install.sh
  PASS 存在 l1/manifest.json
  PASS 存在 l1/capability/browser-farm.json
  PASS 存在 l2/install.sh
  PASS 存在 l2/manifest.json
  PASS 存在 l3/install.sh
  PASS 存在 l3/manifest.json
  PASS 存在 l3/schema/platform.schema.json
  PASS 存在 l3/check-bundle-skills.js
-- 1. L1 核心包 kualang-l1
  PASS L1 install（write=1 skip=0 fail=0）
  PASS L1 标记文件可解析（name=kualang-l1 capability=browser-farm）
  PASS L1 --check 幂等（== CHECK: would-write=0 would-skip=1 FAIL=0 ==）
  PASS L1 --check 未改标记文件（shasum 一致 478b40362990…）
  PASS L1 负例 --farm 空目录退出码 1（非 0）
  PASS L1 负例失败原因正确（farm-mcp.js 不存在）
  PASS L1 负例目标 0 写入
-- 2. L2 版本包 kualang-cbec
    == 汇总: write=83 skip=0 fail=0 ==
    INSTALL OK
  PASS L2 install 退出码 0
  PASS L2 汇总 write=83 skip=0 fail=0
  PASS L2 落点文件数 57
  PASS L2 skills=8
  PASS L2 skills 落点与源目录一致（含附属文件）
  PASS L2 工作区随包脚本 7 个 + faq.json 齐全
-- 3. L3 平台包（逐个装）
  PASS 平台清单 7 个
  PASS 平台 aliexpress 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 amazon skills=23
  PASS 平台 amazon 安装（write=55 skip=0 fail=0，落点 55）
  PASS 平台 amazon bundle skills 与分层 skills 一致（46 个文件）
  PASS 平台 ebay 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 lazada 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 shopee 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 tiktokshop 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 walmart 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台落点目录 7 个
-- 4. 全量 --check（不写）
  PASS L2 --check 幂等（== CHECK: would-write=0 would-skip=83 FAIL=0 ==）
  PASS 平台 aliexpress --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 amazon --check 幂等（== CHECK: would-write=0 would-skip=55 FAIL=0 ==）
  PASS 平台 ebay --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 lazada --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 shopee --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 tiktokshop --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 walmart --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS --check 未改任何文件（shasum 一致 45f3edb5b085…）
-- 5. 负例：空目录装平台必须 FAIL 且 0 写入
  PASS 空目录装 ebay 退出码 1（非 0）
  PASS 空目录失败原因正确（未装 L2）
  PASS 空目录 0 写入
-- 5a. 负例：农场版本不满足必须 FAIL 且 0 写入
    FAIL browser-farm 1.1.0 < 要求 99.0.0
  PASS L3 农场版本闸负例（rc=1，目标 0 写入）
-- 5b. 负例：requires 键名错误必须 FAIL 且 0 写入
  PASS L3 requires 错误键名负例（rc=1，目标 0 写入）
-- 6. 取页器与平台预设（静态）
  PASS node --check farm-probe.js
  PASS 平台预设 7 个齐全
  PASS 预设 aliexpress.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 amazon.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 ebay.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 lazada.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 shopee.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 tiktokshop.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 walmart.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS L3 aliexpress 接上取数预设（browser-farm.probe_preset=aliexpress）
  PASS L3 amazon 接上取数预设（browser-farm.probe_preset=amazon）
  PASS L3 ebay 接上取数预设（browser-farm.probe_preset=ebay）
  PASS L3 lazada 接上取数预设（browser-farm.probe_preset=lazada）
  PASS L3 shopee 接上取数预设（browser-farm.probe_preset=shopee）
  PASS L3 tiktokshop 接上取数预设（browser-farm.probe_preset=tiktokshop）
  PASS L3 walmart 接上取数预设（browser-farm.probe_preset=walmart）
-- 7. SP-API 本地假服务
  PASS SP-API 本地假服务自检（catalog / report）
-- 7a. eBay 本地假服务
  PASS eBay 本地假服务自检（token / search / 429 重试）
-- 7b. 降级链
  PASS 降级链自检（T1 / T3 / E_NO_TIER）
-- 7c. AliExpress 离线币种闸门
  PASS AliExpress 美元样本（≥10 条、分转美元、sold 解析、未验证字段为 null）
  PASS AliExpress 日元样本被拒（非 0 退出，无商品或价格）
-- 7d. 粗筛报告口径
  PASS 粗筛离线运行退出码 0
  PASS 粗筛 Markdown 五节齐全
  PASS 粗筛 CSV 15 项指标齐全，Markdown 和 CSV 无决策词
  PASS 删掉 amazon_products.json 后，上架月龄中位数为 NA（含缺失原因）
-- 8. 授权与安装包自检
  PASS licence-selftest.sh
  PASS installer-selftest.sh
  PASS 真工作区未被写（mtime 未变）

== 汇总: PASS=75 FAIL=0 WARN=0 ==
RESULT: READY
```

```bash
bash distribution/flow-smoke.sh
```

```text
== kualang 业务流冒烟 ==
  WARN 插件缺源：prompt-enhancer
  WARN 插件缺源：retrace
  WARN 插件缺源：rollback-withdraw
  PASS out/选品打分.csv
  PASS out/选品打分.csv 内容校验
  PASS out/上架包/
  PASS out/上架包 内容校验
  PASS out/运营日报.md
  PASS out/运营日报.md 内容校验
  PASS out/客服处理.csv
  PASS out/客服处理.csv 内容校验
  PASS 打分缺列样例两行均为 [D] 补数据，无正向决策
== 汇总: PASS=9 FAIL=0 WARN=3 ==
RESULT: READY
```

### 5. 镜像校验

```bash
diff -qr distribution/l2/skills distribution/l2/bundle/skills
```

退出码 0，无输出。

### 6. Python 3.9.6 独立复核

```bash
/usr/bin/python3 --version
```

```text
Python 3.9.6
PASS Python 3.9.6：15 项指标、缺字段/真实零值、离线无子进程、两秒间隔、20 个商品页上限
```

价格带的 P25 与 P75 采用样本范围内的线性插值。新品占比按未取整的月龄与 12 比较，月龄中位数显示到 1 位小数。Amazon 成功响应的 JSON 未提供 HTTP 状态和币种校验字段，报告按字段可得性标为 NA。
