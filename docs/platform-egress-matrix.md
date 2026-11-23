# 平台出口可用性矩阵（直连，无代理）

采集时间：2026-11-23 14:30–14:31（Asia/Shanghai），即 `2026-11-23T06:30:48Z` – `06:31:27Z`。
采集方式：`distribution/connectors/farm-probe.js --cache-bust`，**不登录、不下单、每站只打一次**，走 `farm/mcp/farm-mcp.js` 建会话 → goto → eval 取证据 → 删会话。
环境：本机直连（未挂代理桥），headless Chromium，`engine=chromium`，账号 `e2e-smoke`，`--cache-bust` 加唯一 `_cb` query。

## 矩阵

| 平台 | 搜索页 URL（已去掉 `_cb`） | status | 证据标题 | item_count | container_count | transferSize | 时间(UTC) |
|---|---|---|---|---|---|---|---|
| amazon | `https://www.amazon.com/s?k=wireless+earbuds` | `ok`（修订轮） | `Amazon.com : wireless earbuds` | 20 | 22 | 209410 | 06:34:42 |
| ebay | `https://www.ebay.com/sch/i.html?_nkw=wireless+earbuds` | `blocked` | `Error Page \| eBay` | 0 | — | 2192 | 06:30:55 |
| walmart | `https://www.walmart.com/search?q=wireless+earbuds` | `blocked`（修订轮） | `Robot or human?` | 0 | — | 3669 | 06:34:20 |
| aliexpress | `https://www.aliexpress.com/w/wholesale-wireless-earbuds.html` | `error`（`E_GOTO`） | — | 0 | — | — | 06:31:04 |
| shopee | `https://shopee.sg/search?keyword=wireless%20earbuds` | `empty` | `Shopee Singapore \| Cheaper, Faster On Shopee` | 0 | 0 | 26031 | 06:31:13 |
| lazada | `https://www.lazada.sg/catalog/?q=wireless%20earbuds` | `error`（`E_GOTO`） | — | 0 | — | — | 06:31:18 |
| tiktokshop | `https://shop.tiktok.com/search?q=wireless+earbuds` | `error`（`E_NOT_FOUND`）† | `404 Not Found` | 0 | 0 | 437 | 06:31:27 |

7 站修正后分布：`ok=1`（amazon，20 条）/ `blocked=2`（ebay、walmart）/ `error=3`（aliexpress、lazada、tiktokshop †）/ `empty=1`（shopee）。
† tiktokshop 那一行是**首轮同一次采样**（HTTP 404，tranferSize=437），按修订后的契约重新归类为 `error` / `E_NOT_FOUND`；**没有再打这个站**。其余未标注的行走首轮原样。

## 首轮两处错判（事实记录，不掩盖）

1. **walmart 首轮漏报成 `empty`**：探针 `BLOCK_PATTERNS` 只有 `sorry/error_page/access_denied/captcha`，没覆盖 Walmart 的 `Robot or human?` 机器人墙，于是拦截页落到了 `empty`。
2. **复核时更糟：同一页被判成 `ok`**（Chief 复现原文）：

   ```json
   {"status":"ok","final_url":"https://www.walmart.com/blocked?url=...","item_count":1,
    "title":"Robot or human?","matched":[]}
   EXIT=0
   ```

   原因：未给 `--list` 时探针走单页模式，`title` 选择器取的是文档标题，`Robot or human?` 非空 → `item_count=1` → `ok`。**拦截页被当成有数据，这是取页器最严重的一类错。**
3. 修复（同轮已自证，见文末）：blocked 判定提前且有 URL 判据、`blocked` 压过 items 提取、主文档 404 归 `E_NOT_FOUND`。

## 逐站证据（探针输出原文摘录）

### amazon — `ok`（修订轮，20 条；价格是日元）

```json
{"status":"ok","final_url":"https://www.amazon.com/s?k=wireless+earbuds&_cb=1795415682813-5gmwkn",
 "title":"Amazon.com : wireless earbuds","item_count":20,"container_count":22,
 "nav":{"transfer_size":209410,"decoded_body_size":1224261,"duration":3358,"response_status":200,"cache_hit":false},
 "first":{"title":null,"price":"JPY 4,403"},"last":{"title":null,"price":"JPY 3,196"},
 "cleanup":{"deleted":true,"delete_ok":true,"data_retained":true}}
```

判读：这次没有被 302 到 `.co.jp`（首轮那次是 `final_url=https://www.amazon.co.jp/s?k=...&ref=mr_direct_us_jp_jp`），但**价格全是日元**（`JPY 4,403` / `JPY 3,196`），说明出口地理仍是日本，只是展示域名不同。条目本身取到 20 条（价格字段全命中）；`title` 字段为 `null` 是选择器问题——`title=h2 a span` 没命中华南卡片标题（新布局），本轮按「amazon 只重跑一次」没有再打第三次。

### ebay — `blocked`（反爬拒绝）

```json
{"status":"blocked","final_url":"https://www.ebay.com/sch/i.html?_nkw=wireless+earbuds&_cb=1795415455887-mhjzqz",
 "title":"Error Page | eBay",
 "body_snippet":"SORRY Something went wrong on our end 0.483d3117.1795415456.297fe59b Please go back and try again. Copyright © 1995-2026 eBay Inc. All Rights Reserved.",
 "nav":{"transfer_size":2192,"decoded_body_size":1892,"duration":1065,"cache_hit":false}}
```

判读：真从网上取到了 `2192` 字节的 `Error Page`，命中 `sorry`/`error_page` 两条特征。与历史结论一致：eBay 搜索页在非目标国直连出口上一律被拦。

### walmart — `blocked`（修订轮，修复后重跑）

```json
{"status":"blocked",
 "final_url":"https://www.walmart.com/blocked?url=L3NlYXJjaD9xPXdpcmVsZXNzK2VhcmJ1ZHMmX2NiPTE3OTU0MTU2NjExNjYtYmVnNXB0&uuid=",
 "title":"Robot or human?",
 "matched":["robot_or_human","activate_and_hold","url_blocked"],
 "item_count":0,"nav":{"transfer_size":3669,"decoded_body_size":15566,"duration":2895,"response_status":200,"cache_hit":false}}
EXIT=2
```

判读：拦截页返回 HTTP 200，标题与正文命中 `robot_or_human`/`activate_and_hold`，`final_url` 路径命中 `url_blocked`——三条判据同时命中，`blocked` 压过 items 提取，`EXIT=2`。这正是修复前被漏成 `empty`、复核时被错判成 `ok` 的同一个页面。

### aliexpress — `error`（goto 未完成）

```json
{"status":"error","error":{"code":"E_GOTO","message":"goto 未成功",
 "detail":"{\"ok\":false,\"url\":\"https://www.aliexpress.com/w/wholesale-wireless-earbuds.html?_cb=1795415464807-j7yhu4\",\"readyState\":\"interactive\"}"}}
```

判读：导航停在 `readyState=interactive`，没等到 `complete`，因此没有页面标题与条目。可能是重定向链/SPA 加载未完成，也可能是反爬；本次证据不足以区分。

### shopee — `empty`（只拿到 SPA 壳）

```json
{"status":"empty","final_url":"https://shopee.sg/search?keyword=wireless+earbuds&_cb=1795415473770-8qo14m",
 "title":"Shopee Singapore | Cheaper, Faster On Shopee",
 "body_snippet":"Skip to main content","item_count":0,"container_count":0,
 "nav":{"transfer_size":26031,"decoded_body_size":167235,"duration":3016,"cache_hit":false}}
```

判读：HTML 壳取到了（167KB），但没有商品卡片——SPA 内容需要登录态/更长等待/接口数据，直连只读一次拿不到。

### lazada — `error`（goto 未完成）

```json
{"status":"error","error":{"code":"E_GOTO","message":"goto 未成功",
 "detail":"{\"ok\":false,\"url\":\"https://www.lazada.sg/tag/wireless-earbuds/?q=wireless+earbuds&_cb=1795415479069-cnx9o4&catalog_redirect_tag=true\",\"readyState\":\"interactive\"}"}}
```

判读：`/catalog/` 被重定向到 `/tag/...`，随后停在 `interactive`。同样是「有响应但没加载完」，无法归因为拦截或纯 SPA。

### tiktokshop — `empty`（URL 本身 404）

```json
{"status":"empty","final_url":"https://shop.tiktok.com/search?q=wireless+earbuds&_cb=1795415487720-rdcerw",
 "title":"404 Not Found","body_snippet":"404 Not Found TLB","item_count":0,"container_count":0,
 "nav":{"transfer_size":437,"decoded_body_size":546,"duration":646,"cache_hit":false}}
```

判读：`shop.tiktok.com/search` 这个路径不存在（404，437 字节）。**这一行只证明「我选的这个 URL 是 404」，不能代表 TikTok Shop 的可达性**——公开可用的搜索入口本轮没确认到。修订后契约对同一份样本的归类是 `error` / `E_NOT_FOUND`（主文档 `responseStatus=404`），本轮没有重打该站。

## 结论：是不是所有平台的搜索页都必须有代理？

**不是「连不上」，但只有 1/7 取到条目，且取到的不是目标国数据——所以仍然必须有目标国代理。** 分层说：

1. **网络层 7 站全部出得去。** 7 条都拿到了非 0 的 `transfer_size`（437–209410 字节）且 `cache_hit=false`，没有一条是 `E_CACHE_HIT` 或 DNS/连接错误。所以「没有代理就连不上这些站」不成立。
2. **可用数据只有 1/7。** amazon 修订轮取到 20 条，但价格是 `JPY`（日元）——出口地理是日本，不是美国；其余 6 站 0 条：
   - **反爬墙**：eBay `Error Page`（真 blocked）、Walmart 机器人墙（修复后 blocked）。
   - **加载未完成**：AliExpress、Lazada 停在 `readyState=interactive`。
   - **SPA 壳**：Shopee 只有 `Skip to main content`。
   - **入口错误**：TikTok Shop 我选的 URL 是 404（`E_NOT_FOUND`），不代表平台不可达。
3. **要拿美国站可用数据，必须走美国出口代理（`socks5h://`）。** 直连只能证明「站点可达」，证明不了「数据可采」；地域与反爬两道只能靠出口 IP 与登录态解决。

一句话回答：**7 站都能直连出网，但直连只拿到 amazon 的 20 条日元价（地域错），其余全部被拦或取不到；生产取数仍然必须配目标国出口代理，首选 `socks5h://`。**

## 缺口（本矩阵证明不了的事）

1. **amazon 的 `title` 字段没取到**：`title=h2 a span` 在修订轮 `null`（20 条只靠 price 命中）；要拿到标题文案得再打一次，换 `title=h2 span` 之类。本轮按「amazon 只重跑一次」没有再打。
2. **walmart 只验证了这一种墙**：新加特征（`Just a moment` / `cf-challenge` / `unusual traffic` / `px-captcha` 等）只有静态特征，没有真实命中样本。
3. **tiktokshop 入口未确认**：`shop.tiktok.com/search` 是 404；需要确认公开搜索入口（或改走商品详情页）后再采一次；该行是重新归类，不是重跑。
4. **aliexpress/lazada 归因不足**：只有 `readyState=interactive`，没有页面标题/正文，无法区分反爬与 SPA 超时。
5. **amazon 两次结果不一致**：首轮 302 到 `amazon.co.jp`，修订轮停在 `amazon.com` 但价格仍是日元；只能得出「出口地理非美国」，不能得出「一定重定向到日本站」。
6. **全部是「非目标国直连出口」的结果**：拿到代理后需整表重跑一次，矩阵才有生产意义。
7. **每站采样一次**：除 walmart/amazon 的修订轮外，其余每站只有一次采样，不排除偶发。

## 复跑命令（每站一次，勿连打）

> **有代理后不用手写 URL/选择器**：预设已固化在 `distribution/connectors/platforms/<id>.json`，直接
> `node distribution/connectors/farm-probe.js --platform amazon --query wireless+earbuds --proxy socks5h://127.0.0.1:18082 --cache-bust`
> 重跑本矩阵（其余平台把 `amazon` 换成 `ebay / walmart / shopee / lazada / aliexpress / tiktokshop`）。
> 注意各平台 `verified` 里除 amazon 的 `price`/`list_selector` 外都必须写 `未验`，重跑后才算验证过。


```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/xavier/Projects/DS-Cross-Border-Workbench

# amazon（卡片内选择器；title=h2 a span 已实测未命中，复跑时试 h2 span）
node distribution/connectors/farm-probe.js \
  --url 'https://www.amazon.com/s?k=wireless+earbuds' \
  --list 'div[data-component-type="s-search-result"]' \
  --selectors 'title=h2 span,price=.a-price .a-offscreen' --cache-bust

# ebay
node distribution/connectors/farm-probe.js \
  --url 'https://www.ebay.com/sch/i.html?_nkw=wireless+earbuds' \
  --list 'li.s-item' --selectors 'title=.s-item__title,price=.s-item__price' --cache-bust

# walmart
node distribution/connectors/farm-probe.js \
  --url 'https://www.walmart.com/search?q=wireless+earbuds' \
  --list 'div[data-item-id]' --selectors 'title=[data-automation-id="product-title"],price=[data-automation-id="product-price"]' --cache-bust

# aliexpress
node distribution/connectors/farm-probe.js \
  --url 'https://www.aliexpress.com/w/wholesale-wireless-earbuds.html' \
  --list 'div[class*="search-item-card-wrapper"]' --selectors 'title=h3,price=.price-current' --cache-bust

# shopee
node distribution/connectors/farm-probe.js \
  --url 'https://shopee.sg/search?keyword=wireless%20earbuds' \
  --list 'div[data-sqe="item"]' --selectors 'title=[data-sqe="name"]' --cache-bust

# lazada
node distribution/connectors/farm-probe.js \
  --url 'https://www.lazada.sg/catalog/?q=wireless%20earbuds' \
  --list 'div[data-qa-locator="product-item"]' --selectors 'title=.RfADt a,price=.aBrP0' --cache-bust

# tiktokshop（入口待确认，当前 URL 404，复跑前先换入口）
node distribution/connectors/farm-probe.js \
  --url 'https://shop.tiktok.com/search?q=wireless+earbuds' --cache-bust
```

加代理时在命令后追加 `--proxy socks5h://127.0.0.1:18082`（桥按 `docs/proxy-runbook.md` 起，上游用 `socks5h://` 远程 DNS）。

## 本轮自证

**四条回归（原文摘录）**

```json
// 1) walmart 搜索页 → blocked / EXIT=2
{"status":"blocked","final_url":"https://www.walmart.com/blocked?url=...","title":"Robot or human?",
 "matched":["robot_or_human","activate_and_hold","url_blocked"],"item_count":0}
EXIT=2

// 2) example.com → ok / EXIT=0
{"status":"ok","final_url":"https://example.com/?_cb=...","title":"Example Domain","matched":[],
 "item_count":1,"nav":{"transfer_size":634,"response_status":200,"cache_hit":false}}
EXIT=0

// 3) books.toscrape 列表 → ok 20 条 / EXIT=0
{"status":"ok","title":"All products | Books to Scrape - Sandbox","item_count":20,"container_count":20,
 "first":{"title":"A Light in the ...","price":"£51.77"},"nav":{"transfer_size":5576,"response_status":200}}
EXIT=0

// 4) 明确 404 → error / E_NOT_FOUND / EXIT=1
{"status":"error","final_url":"https://example.com/definitely-not-here-1795415672?_cb=...",
 "nav":{"transfer_size":634,"response_status":404,"cache_hit":false},
 "error":{"code":"E_NOT_FOUND","message":"主文档 HTTP 404（页面不存在），不是可用数据页"}}
EXIT=1
```

**amazon 修订轮**：`status=ok`、`item_count=20`、`container_count=22`、`transfer_size=209410`、`first.price="JPY 4,403"`、`EXIT=0`。

**收尾**：台账 `accounts: 10`、`running: 0`（每站 `cleanup.delete_ok=true`，未新增行）；`farm/` 零改动（`git status --porcelain -- farm/` 为空）；`/tmp/probe-reg`、`/tmp/egress-probe` 均已删除。
