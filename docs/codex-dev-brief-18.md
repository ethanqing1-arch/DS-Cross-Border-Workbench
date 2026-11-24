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
