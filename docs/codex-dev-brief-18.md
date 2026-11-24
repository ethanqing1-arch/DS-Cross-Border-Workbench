# 交接单 18：接 AliExpress 美国区为第二个免费真实数据源

日期：2026-11-24
上游：交接单 17（`1e0e33d`，Amazon 字段扩容与安全闸）

## 这单要解决什么

选品管道现在只有 Amazon 美国站一个真实数据源。2026-11-24 实测发现 **AliExpress 美国区可直连取数、不需要代理、不需要凭证**，是第二个免费真实源，且能提供货源侧价格（此前 `cogs_cny` 字段标着「只能人工查 1688」）。

这单把它做成零依赖脚本，并且**先立一道币种闸门**——这个源最大的坑是「不带区域 cookie 会静默返回日元区」，不设闸门就会把日元价当美元写进打分表。

## 已实测的证据（原文，2026-11-24）

带区域 cookie 直连，取到美国区/美元：

```
URL    https://www.aliexpress.com/w/wholesale-pet-slow-feeder.html
cookie aep_usuc_f=site=glo&c_tp=USD&region=US&b_locale=en_US
http=200  bytes=901302
html lang = "en"
US $ 价格命中 = 114
唯一商品链接（aliexpress.com/item/<id>.html）= 60
sold 文案样本：11 sold / 36 sold / 13 sold / 31 sold / 19 sold / 293 sold
```

结构化字段原样：

```
"salePrice":{"discount":86 ... "salePriceAmount":"382"
```

**单位陷阱（务必按此实现）**：`salePriceAmount` 是**分**，`"382"` 对应页面显示 `US $3.82`。同一页前五条对照：

```
salePriceAmount  382  391  342  109  343
页面 US 价      $3.82 $3.91 $3.42 $1.09 $3.43
```

直接把它当美元用，金额会小 100 倍。

### 反例：不带区域 cookie

```
同一 URL 不带 cookie → html lang = "ja"，US $ 命中 = 0
```

这条是 T2 闸门的依据：**页面语言与价格符号必须同时校验**，否则会把日元区数据当美元。

### 未验证，不许猜

| 项 | 状态 |
|---|---|
| `starRating` | 901,302 字节 HTML 里命中 **0** 次，评分字段位置未确认 → 一律输出 `null` |
| `originalPrice` | 用 `"originalPrice"[^}]{0,80}` 在 HTML 里命中 0 次 → 原价字段位置未确认，取不到就 `null` |
| 翻页 | 第二轮 `page=2` 报告的 `code=200 / cards=20` 我没有独立复核 → 实现后由你自证 |
| 汇率 | 本单**不做** USD→CNY 换算 |

另注：`distribution/connectors/platforms/aliexpress.json` 里写的「未验：goto 未完成」是**农场 Chromium 的 T3 路径**，与 curl 直连是两条不同的路，不要拿那条结论否定本单。

## T1 `fetch_aliexpress.py`（最高优先）

新增 `distribution/l2/skills/market-research/scripts/fetch_aliexpress.py`，风格逐条对齐同目录 `fetch_amazon.py`：

- python 3.9.6 兼容，**只用标准库**；HTML 用系统 `curl` 子进程取，沿用 `fetch_amazon.py:31-50` 的 `-w "\n__HTTP__%{http_code}"` 手法、UA 池、`--compressed`、超时与重试口径。
- 子命令：`search "<关键词>" --limit N [--page N] [--csv] [--out <dir>]`。
- 关键词转 URL 用连字符形式（`pet slow feeder` → `pet-slow-feeder`），这是 `platforms/aliexpress.json` 的模板要求；不要用 `+`。
- 输出 JSON 到 stdout（诊断走 stderr），字段：

```
keyword / url / http / lang / currency_verified / count / rows[] / degraded
rows[] = item_id, title, sale_price_usd, original_price_usd, discount_pct,
         sold_text, sold_count, rating
```

- `sale_price_usd` = `salePriceAmount` / 100，保留两位小数。
- `discount_pct` = `{"discount":86` 里的 86（整数，不带 `%`）。
- `sold_count` 由 `sold_text` 解析：`11 sold`→11、`1K+ sold`→1000、`10K+ sold`→10000；解析不出→`null`，`sold_text` 保留原文。
- 取不到的字段一律 `null`，并把字段名写进 `degraded`。**不许填估算值、不许默认 0。**

**边界**：`--limit` 上限 60，`--page` 上限 3，两次请求间隔 ≥2 秒，单次运行不超过 3 页。

## T2 币种闸门（比 T1 更优先，先写这道）

三道，缺一不可：

1. **页面级**：HTML 必须同时满足 `lang="en"` **且** `US $` 命中数 ≥1。任一不满足 → `currency_verified=false`、`rows=[]`、`degraded` 写明原因，**退出码非 0**。
2. **行级**：每条记录的价格必须来自 `salePriceAmount`，且该条目在页面上的价格文本以 `US $` 出现。行内校验不过 → 该行 `sale_price_usd=null` 并进 `degraded`，**不许把别的币种符号当美元**。
3. **反例自证**：不带区域 cookie 跑同一关键词，必须落到 `currency_verified=false` 且 `rows=[]`，**不许输出任何价格**。

## T3 镜像同步与文档

1. **新脚本必须同步到 `distribution/l2/bundle/skills/market-research/scripts/fetch_aliexpress.py`。** `distribution/l2/install.sh:188-192` 有 `diff -qr "$SRC/skills" "$SRC/bundle/skills"`，不一致直接 `FAIL bundle/skills 与 skills/ 不一致`。交接单 17 漏了这一步，你顺手把 `fetch_amazon.py` 两处也补齐（当前 `diff -qr` 已经有这条 drift）。
2. `distribution/l2/skills/market-research/references/free-stack-verified.md` 补一节「AliExpress 美国区实测记录」，写清抓取时间、cookie、字节数、四个数字（lang / US $ 命中 / 商品链接数 / sold 样本），以及 `salesPriceAmount` 是分这个坑。**该文件交接单 17 也在改，按顺序追加，不要覆盖它写的内容。**
3. 不要动 `distribution/l2/workspace/data/candidates.sample.csv`。

## T4 离线回归（不联网）

`verify.sh` 不能依赖外网，所以回归用裁剪过的 fixture：

1. 从这次实测的 901,302 字节 HTML 裁出卡片结构（去掉 `<script>`/`<style>`/图片 base64），存到 `distribution/l2/skills/market-research/scripts/fixtures/aliexpress_us_trim.html`，体积控制在 200 KB 以内。
2. 给脚本加 `--html <path>` 参数从本地文件解析（跳过网络），供回归使用。
3. `distribution/verify.sh` 增加两条断言：
   - 正例：fixture 解析出 **≥10 条**，且全部 `sale_price_usd` 非 null。
   - 负例：把 fixture 里的 `US $` 全替换成 `JP¥` 后解析，必须 `currency_verified=false` 且 `rows` 为空。

## 验收（你自己跑，贴原文）

```bash
# 1. 真实抓取
python3 distribution/l2/skills/market-research/scripts/fetch_aliexpress.py search "pet slow feeder" --limit 10

# 2. 币种反例（必须 degraded 且 rows 为空）
#    不带区域 cookie 跑同一关键词，贴原文

# 3. 离线回归
bash distribution/verify.sh
bash distribution/flow-smoke.sh

# 4. 镜像必须零 drift
diff -qr distribution/l2/skills distribution/l2/bundle/skills
#    期望无输出
```

## 边界

- 不碰 `farm/`、台账、`~/.dsh`、DS Bot 自身、系统设置、launchd。
- **不改** `fetch_amazon.py` 的抓取逻辑和 `score_products.py`——那是交接单 17 的范围；你只按 T3 第 1 条把那两个文件的镜像副本补齐。
- 不写任何真实凭证；不加需要花钱的依赖；不登录 AliExpress。
- **不许编数字**：取不到就是 `null`，不许填估算值当实测。
- 抓取要礼貌：两次请求间隔 ≥2 秒，一次不超过 3 页 / 60 条。
- 完成后工作区要干净，改动只在本单范围内。

## 收尾

2026-11-24 验收。三次真实请求串行执行，相邻命令之间等待至少 2 秒。
总装和冒烟使用临时本地网关 `GATEWAY_URL=http://127.0.0.1:55951`（模拟版本 `1.1.0`）。

### 真实抓取

退出码 `0`。

```text
$ python3 distribution/l2/skills/market-research/scripts/fetch_aliexpress.py search "pet slow feeder" --limit 10
{
 "keyword": "pet slow feeder",
 "url": "https://www.aliexpress.com/w/wholesale-pet-slow-feeder.html",
 "http": 200,
 "lang": "en",
 "currency_verified": true,
 "count": 10,
 "rows": [
  {
   "item_id": "3256812972203717",
   "title": "Slow Feeder Bowl for Pets, Purple Rainbow",
   "sale_price_usd": 4.08,
   "original_price_usd": null,
   "discount_pct": 86,
   "sold_text": "11 sold",
   "sold_count": 11,
   "rating": null
  },
  {
   "item_id": "3256812962130942",
   "title": "Silicone Slow Feeder Bowl for Pets, Blue Rainbow",
   "sale_price_usd": 4.17,
   "original_price_usd": null,
   "discount_pct": 85,
   "sold_text": "36 sold",
   "sold_count": 36,
   "rating": null
  },
  {
   "item_id": "3256812962262358",
   "title": "Gobble Stopper Slow Feeder, Small,1 CT",
   "sale_price_usd": 4.68,
   "original_price_usd": null,
   "discount_pct": 83,
   "sold_text": "13 sold",
   "sold_count": 13,
   "rating": null
  },
  {
   "item_id": "3256813025562701",
   "title": "Pet Slow Feeder Dog Lick Bowl With Rolling Ball Slow Feeder Anti-Choking For Dogs Cats Yogurt Bone Broth Liquid Treats Interactive Pet Bowl",
   "sale_price_usd": 1.09,
   "original_price_usd": null,
   "discount_pct": 91,
   "sold_text": "31 sold",
   "sold_count": 31,
   "rating": null
  },
  {
   "item_id": "3256812962250324",
   "title": "Silicone Slow Feeder Compartment Pet Mat, Purple, 12\" x 8\"",
   "sale_price_usd": 4.69,
   "original_price_usd": null,
   "discount_pct": 83,
   "sold_text": "19 sold",
   "sold_count": 19,
   "rating": null
  },
  {
   "item_id": "3256813459713423",
   "title": "2 Packs Dog Lick Pad with Strong Suctions Silicone Slow Feeder for Liquid Thick Treats Interactive Pet Training Pad for Cats Dogs Bathing Grooming Black Grey Pet Supplies",
   "sale_price_usd": 3.85,
   "original_price_usd": null,
   "discount_pct": 87,
   "sold_text": null,
   "sold_count": null,
   "rating": null
  },
  {
   "item_id": "3256811467456152",
   "title": "1Pc Slow Feeder Dog Bowl Anti-choking Puppy Food Bowl Anti-slip Pet Slow Eating Dog Dishes Puzzle Feeders for Dogs Small Medium",
   "sale_price_usd": 2.33,
   "original_price_usd": null,
   "discount_pct": 62,
   "sold_text": "1K+ sold",
   "sold_count": 1000,
   "rating": null
  },
  {
   "item_id": "3256806005096603",
   "title": "Pet Slow Feeder Pet Dog Slow Feeder Bowl Non Slip Puzzle Bowl Anti-Gulping Pet Slower Food Feeding Dishes Dog Bowl for Medium Small Dogs Puppy",
   "sale_price_usd": null,
   "original_price_usd": null,
   "discount_pct": null,
   "sold_text": "293 sold",
   "sold_count": 293,
   "rating": null
  },
  {
   "item_id": "3256811676942186",
   "title": "Slow Feeder Dog Bowls for Liquid Treat, Anti-Slip【Entertained Ball-in】 Bone Broth Dog Lick Bowl,Pet Licking Bowls",
   "sale_price_usd": 3.22,
   "original_price_usd": null,
   "discount_pct": 88,
   "sold_text": "56 sold",
   "sold_count": 56,
   "rating": null
  },
  {
   "item_id": "3256813365087279",
   "title": "2 Pcs Slow Feeder Dog Cat Bowl Non Slip Maze Puzzle Pet Feeding Dish Grey Black Interactive Slow Eating Digestion for Small Medium Puppy Kitten",
   "sale_price_usd": 4.15,
   "original_price_usd": null,
   "discount_pct": 87,
   "sold_text": null,
   "sold_count": null,
   "rating": null
  }
 ],
 "degraded": [
  "sale_price_usd",
  "original_price_usd",
  "discount_pct",
  "sold_text",
  "sold_count",
  "rating"
 ]
}
```

### 无区域 cookie 反例

退出码 `1`。

```text
$ python3 distribution/l2/skills/market-research/scripts/fetch_aliexpress.py search "pet slow feeder" --limit 10 --no-cookie
{
 "keyword": "pet slow feeder",
 "url": "https://www.aliexpress.com/w/wholesale-pet-slow-feeder.html",
 "http": 200,
 "lang": "ja",
 "currency_verified": false,
 "count": 0,
 "rows": [],
 "degraded": [
  "lang_not_en",
  "usd_price_marker_missing",
  "region_cookie_disabled"
 ]
}
```

### 第 2 页复核（Python 3.9.6）

退出码 `0`。

```text
$ /usr/bin/python3 distribution/l2/skills/market-research/scripts/fetch_aliexpress.py search "pet slow feeder" --limit 10 --page 2
{
 "keyword": "pet slow feeder",
 "url": "https://www.aliexpress.com/w/wholesale-pet-slow-feeder.html?page=2",
 "http": 200,
 "lang": "en",
 "currency_verified": true,
 "count": 10,
 "rows": [
  {
   "item_id": "3256813002666713",
   "title": "Christmas Sweater Silicone Pet Lick Mat Suction Cup Anti Slip Slow Feeder Mat For Dog Cat Puppy Kitten Pet Feeding Supplies",
   "sale_price_usd": 8.88,
   "original_price_usd": null,
   "discount_pct": 75,
   "sold_text": "1 sold",
   "sold_count": 1,
   "rating": null
  },
  {
   "item_id": "3256809234029914",
   "title": "Pet Lick Silicone Mat Slow Feeder Dog Food Plate Bathing Distraction Sucker Training Feeder Supplies for Dogs",
   "sale_price_usd": 1.09,
   "original_price_usd": null,
   "discount_pct": 79,
   "sold_text": "334 sold",
   "sold_count": 334,
   "rating": null
  },
  {
   "item_id": "3256809396079780",
   "title": "Smart Pet Feeder Automatic Cat Feeder Dog Slow Food Machine With Timed Quantitative Automatic Cat Food Dispenser Cat Dog Bowl",
   "sale_price_usd": 51.09,
   "original_price_usd": null,
   "discount_pct": 51,
   "sold_text": "4K+ sold",
   "sold_count": 4000,
   "rating": null
  },
  {
   "item_id": "3256813448219813",
   "title": "Pet Feeder Dopamine Multicoloured Tall Pet Feeder with Two Stainless Steel Bowls and Neck Support Double Pet Bowl Pet Double Bowl Pet Food",
   "sale_price_usd": 8.99,
   "original_price_usd": null,
   "discount_pct": 42,
   "sold_text": null,
   "sold_count": null,
   "rating": null
  },
  {
   "item_id": "3256807074986783",
   "title": "Pet Product Bone Plastic Pet Food Bowl Doggy Puppy Bowl Slow Feeder Dog Bowl",
   "sale_price_usd": 1.09,
   "original_price_usd": null,
   "discount_pct": 91,
   "sold_text": "21 sold",
   "sold_count": 21,
   "rating": null
  },
  {
   "item_id": "3256812076687114",
   "title": "Stainless Steel Slow Feeder Dog Bowls Pet Anti Choking Spine Protection Double Sided Use Anti Overturning Cat Bowl Pet Supplies.",
   "sale_price_usd": 1.09,
   "original_price_usd": null,
   "discount_pct": 95,
   "sold_text": "24 sold",
   "sold_count": 24,
   "rating": null
  },
  {
   "item_id": "3256810403951444",
   "title": "Flower Shape Pet Bowl Ceramic Raised Slow Feeder Dog Bowl 15 Degree Tilted Cat Bowl Cute 150ml Pet Water Dispenser Pet Supplies",
   "sale_price_usd": 16.94,
   "original_price_usd": null,
   "discount_pct": 69,
   "sold_text": "3 sold",
   "sold_count": 3,
   "rating": null
  },
  {
   "item_id": "3256812671642310",
   "title": "Pet Feeder 2-in-1 Pet Feeder & Water Dispenser, Large Capacity Automatic Food Bowl for Cats Dogs, Dry Wet Separation, Transparent Plastic, Travel Use",
   "sale_price_usd": 12.95,
   "original_price_usd": null,
   "discount_pct": 71,
   "sold_text": "4 sold",
   "sold_count": 4,
   "rating": null
  },
  {
   "item_id": "3256812404260320",
   "title": "Japanese Kiln Changed Anti Choking Slow Feeder Dog Bowl Non Slip Bottom Anti Spill Pet Food Dish Feeding Bowl",
   "sale_price_usd": 2.39,
   "original_price_usd": null,
   "discount_pct": 89,
   "sold_text": "2 sold",
   "sold_count": 2,
   "rating": null
  },
  {
   "item_id": "3256813046392673",
   "title": "Elevated Ceramic Dog Bowls with Wooden Stand for Small To Medium Sized Dogs, Slow Feeder and Water Bowl Set, Dishwasher Safe, Non Slip Raised Pet Feeding Station, Cream White",
   "sale_price_usd": 17.55,
   "original_price_usd": null,
   "discount_pct": 72,
   "sold_text": "3 sold",
   "sold_count": 3,
   "rating": null
  }
 ],
 "degraded": [
  "original_price_usd",
  "sold_text",
  "sold_count",
  "rating"
 ]
}
```

### 离线总装验收

退出码 `0`。

```text
$ bash distribution/verify.sh
== kualang 三层总装验收 ==
仓库：/Users/xavier/Projects/DS-Cross-Border-Workbench
临时根目录：/tmp/kualang-verify.6whqCX
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
  PASS L1 --check 未改标记文件（shasum 一致 a8fccb0cfe29…）
  PASS L1 负例 --farm 空目录退出码 1（非 0）
  PASS L1 负例失败原因正确（farm-mcp.js 不存在）
  PASS L1 负例目标 0 写入
-- 2. L2 版本包 kualang-cbec
    == 汇总: write=79 skip=0 fail=0 ==
    INSTALL OK
  PASS L2 install 退出码 0
  PASS L2 汇总 write=79 skip=0 fail=0
  PASS L2 落点文件数 53
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
  PASS L2 --check 幂等（== CHECK: would-write=0 would-skip=79 FAIL=0 ==）
  PASS 平台 aliexpress --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 amazon --check 幂等（== CHECK: would-write=0 would-skip=55 FAIL=0 ==）
  PASS 平台 ebay --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 lazada --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 shopee --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 tiktokshop --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 walmart --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS --check 未改任何文件（shasum 一致 617a11bb06be…）
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
-- 8. 授权与安装包自检
  PASS licence-selftest.sh
  PASS installer-selftest.sh
  PASS 真工作区未被写（mtime 未变）

== 汇总: PASS=71 FAIL=0 WARN=0 ==
RESULT: READY
```

### 业务流冒烟

退出码 `0`。

```text
$ bash distribution/flow-smoke.sh
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

### 镜像一致性

退出码 `0`，无输出。

```text
$ diff -qr distribution/l2/skills distribution/l2/bundle/skills
```
