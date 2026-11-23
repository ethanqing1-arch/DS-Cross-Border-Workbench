# connectors/ — 取页探针（blocked / empty / ok / error 四态）

这个目录只放一件事：**把「被拦」和「没数据」分开**。
现有的 `farm_task extract` 在被拦页面上会返回 `{ok:false, fields:{...null}, missing:[...]}`，
肉眼容易读成「页面没数据」；`farm-probe.js` 把这种情形显式归到 `status: "blocked"` 并附证据。

## 用法

```bash
# 需要网关在跑；token 只从环境变量读（GATEWAY_TOKEN，或本机兜底 DSH_SECRET_GATEWAY_TOKEN）
# 单页模式（一页一条）
node distribution/connectors/farm-probe.js \
  --url 'https://example.com/' \
  --selectors title,price \
  --cache-bust \
  --account e2e-smoke

# 列表模式（容器内循环出多条）+ 出口代理
node distribution/connectors/farm-probe.js \
  --url 'https://books.toscrape.com/' \
  --list 'article.product_pod' \
  --selectors 'title=h3 a, price=.price_color' \
  --proxy 'http://127.0.0.1:3128'

# 平台预设：URL/容器/字段都从 platforms/<id>.json 读，只需给 query
node distribution/connectors/farm-probe.js \
  --platform amazon --query wireless+earbuds \
  --proxy 'socks5h://127.0.0.1:18082' --cache-bust

# CLI 显式参数优先：覆盖预设里的 URL / 容器 / 字段
node distribution/connectors/farm-probe.js \
  --platform amazon --query usb+cable --url 'https://www.amazon.com/s?k=usb+cable' \
  --selectors 'title=h2 span,price=.a-price .a-offscreen' --cache-bust
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--url` | 必填（用 `--platform` 时可省） | 要取页的公开 URL；给了就覆盖预设模板 |
| `--platform` | 空 | 平台 id（读 `platforms/<id>.json`）或预设文件路径；用预设时 URL/容器/字段都从预设来 |
| `--query` | 空 | 填预设模板里的 `{q}`；模板含 `{q}` 又没给 query 会直接报 `E_PLATFORM_QUERY` |
| `--selectors` | `title` | 逗号分隔字段；`name` 用内置选择器，`name=css` 显式指定 |
| `--list` | 空（不启用） | 列表模式容器 CSS；容器内按 `--selectors` 循环出多条 |
| `--proxy` | 空（直连） | 出口代理，透传给 `farm_session_create`；值不打印、不进日志，只报「已设置/未设置」 |
| `--cache-bust` | 关 | 给 URL 追加唯一 `_cb` query，绕过磁盘缓存；不加时命中缓存会判 `E_CACHE_HIT`（见下） |
| `--account` | `e2e-smoke` | 农场账号名；复用现有账号，台账按 account 主键 upsert，不新增行 |
| `--engine` | `chromium` | 引擎名（linux150 需 attach，不在本探针范围） |
| `--timeout-ms` | `45000` | goto / extract / 列表 eval 的等待上限 |
| `--mcp` | `<仓库>/farm/mcp/farm-mcp.js` | stdio 适配层路径（一般不用改） |

内置选择器（`--selectors` 里只写字段名时）：

| 字段 | CSS |
|---|---|
| `title` | `title`（文档标题元素） |
| `price` | `[itemprop="price"], .s-item__price, .a-price .a-offscreen, .price` |
| 其他 | 字段名本身当作 CSS 选择器 |

## 平台预设（`platforms/`）

七个平台各一个 JSON：`amazon / ebay / tiktokshop / shopee / lazada / walmart / aliexpress`。

```json
{
  "id": "amazon",
  "name": "Amazon 美国站",
  "search_url_template": "https://www.amazon.com/s?k={q}",
  "list_selector": "div[data-component-type=\"s-search-result\"]",
  "fields": { "title": "h2 span", "price": ".a-price .a-offscreen" },
  "verified": {
    "list_selector": "命中：2026-11-23 直连 22 个容器（出口日本）",
    "price": "命中：20/20；值是 JPY 日元，非美元",
    "title": "未验：h2 a span 未命中；h2 span 是候选，未验证"
  },
  "notes": ["要美国站数据必须走美国出口。"]
}
```

- `verified` 只写**真命中过**的字段与证据；没验的一律写 `未验` 并说明原因，**不许猜**。除 amazon 的 `price`/`list_selector` 外，其余平台字段全部是 `未验`（直连被拦 / 加载未完成 / URL 404），见各文件 `notes`。
- 预设字段必填：`id`、`name`、`list_selector`、`fields`（至少一个非空字段），以及 `search_url_template`（除非显式给 `--url`）。缺任何一个都直接报错：`E_PLATFORM_INCOMPLETE` / `E_PLATFORM_NOT_FOUND` / `E_PLATFORM_QUERY`，**绝不静默退回单页默认值**。
- CLI 优先：`--url` > `search_url_template`；`--list` > `list_selector`；`--selectors` > `fields`。
- `{q}` 原样替换（不做 URL 编码）：查询词要自己编码，空格用 `+`；AliExpress 模板要求连字符形式（`wireless-earbuds`）。
- 机制验证不碰电商站：`--platform <fixture.json>` 可以指向任意本地预设文件（回归第 5/6 条）。

## 输出契约

stdout **只有一段 JSON**（诊断信息一律走 stderr）：

```json
{
  "status": "ok | blocked | empty | error",
  "url": "请求 URL",
  "final_url": "取页后 location.href",
  "checked_at": "ISO 时间",
  "account": "e2e-smoke",
  "session_id": "default:e2e-smoke | null",
  "selectors": { "title": "title", "price": "..." },
  "list": "article.product_pod | null",
  "platform": { "id": "amazon", "name": "...", "query": "...", "preset": "...", "verified": {}, "notes": [] },  // 未用预设时为 null
  "proxy_set": false,
  "cache_bust": false,
  "nav": { "transfer_size": 634, "decoded_body_size": 577, "duration": 1457, "response_status": 200, "cache_hit": false },
  "fields": { "title": "...", "price": null },
  "missing": ["price"],
  "items": [ { "title": "...", "price": null } ],
  "item_count": 1,
  "container_count": null,
  "evidence": { "page_title": "...", "page_url": "...", "body_snippet": "...", "matched": ["sorry"] },
  "error": null,
  "cleanup": { "deleted": true, "delete_ok": true, "data_retained": true }
}
```

四态判定（**铁律：`ok` 必须 `item_count ≥ 1`**）：

| status | 判定 | 退出码 |
|---|---|---|
| `ok` | 页面未命中拦截特征，且至少一条记录取到非空字段（`item_count ≥ 1`） | `0` |
| `blocked` | 命中拦截特征：标题/正文（SORRY / Error Page / Access Denied / captcha / Robot or human? / Activate and hold / unusual traffic / Verify you are human / Are you a robot / px-captcha / Just a moment / cf-challenge / Access to this page has been denied，大小写不敏感）**或**主文档 URL 路径（`/blocked`、`/captcha`、`/sorry`、`/challenge`）；`evidence.matched` 给出命中项（URL 项以 `url_` 开头），`body_snippet` 给原文片段 | `2` |
| `empty` | 页面未命中拦截特征，但所有字段都为空（`item_count = 0`） | `3` |
| `error` | 探针自身没跑完：token 缺失、网关不可达、会话建/删失败、导航超时、MCP 协议错、**缓存命中（`E_CACHE_HIT`）**、**主文档 404（`E_NOT_FOUND`）**、**主文档其他 ≥400（`E_HTTP_STATUS`）** | `1` |

- **禁止返回 `ok` + `items: []`**；取不到东西必须落到 `blocked`（有证据）或 `empty`。
- **判定顺序固定**：blocked（标题/正文/URL）→ HTTP 状态码 → items 提取。**blocked 压过一切**，不许出现「`ok` 但标题是 Robot or human?」；`ok` 只在未拦截、状态码 <400、且 `item_count ≥ 1` 时出现。
- **缓存不算取数**：页面来自磁盘缓存时 `performance.getEntriesByType('navigation')[0].transferSize === 0`。此时不做 `blocked/empty` 判定，直接 `status: "error"`、`error.code = "E_CACHE_HIT"`、退出码 1；加 `--cache-bust` 重跑（`final_url` 会带 `_cb=` 参数，属正常）。这样「没真上网也返回 ok」的假绿被堵死。
- **单页模式**（无 `--list`）：`items` 是一条记录（`[fields]` 或 `[]`），`fields/missing` 是抽取结果。
- **列表模式**（`--list <容器CSS>`）：`items` 是多条记录；`item_count` 是真正取到字段的条数，`container_count` 是容器命中数（全空卡片被剔除，所以两者可能不同）；`fields/missing` 为 `null`。
- 命中拦截时不再取数（被拦页面取出来的也是空值，跑了只会混淆）；`fields/items` 为 `null/[]`。
- `cleanup` 记录会话收尾：`deleted` 是否删除成功、`data_retained` 是否台账保留（网关固定 `true`）。

## 台账与边界

- 复用 `--account`（默认 `e2e-smoke`）建会话，**用完即删**；台账保留一行（`data_retained: true`），重复跑只更新同一行。
- 只读页面：不登录、不下单、不点广告；不写 `farm/`、不写真工作区、不碰 DS Bot。
- token 只从环境变量读，只经子进程环境传递；不进 argv、不落文件、不打印（只允许报长度）。
- `--proxy` 只透传给建会话；stdout、日志、错误文本都不出现代理值（错误里替换为 `[redacted]`），只报 `proxy_set` 布尔。
- `--proxy` 由 farm 层写成 Chromium 的 `--proxy-server=...`（`farm/farm.js:143`）：**URL 里带账号密码 Chromium 不会做认证**（实测把 `http://user:pass@127.0.0.1:9` 传进去，页面仍直连成功），要认证得走本地代理桥（如 `http://127.0.0.1:18080`）；另外浏览器进程 argv 里会出现代理地址（farm 层行为，本探针的 JSON/日志不出现）。
- 若同账号已有 alive 会话（并发跑），先删掉再重试一次建会话；仍失败则 `status: error`。
- **电商站点无代理会被拦**：eBay 这类搜索页在当前直连出口会返回 `Error Page`（SORRY），指纹再干净也过不了；要拿真数据必须先配代理——这是出口问题，不是代码问题。

## 回归（三条）

```bash
# 1) 列表页：ok 且 item_count ≥ 10（books.toscrape.com 公开列表页，非电商反爬）
node distribution/connectors/farm-probe.js \
  --url 'https://books.toscrape.com/' --list 'article.product_pod' \
  --selectors 'title=h3 a, price=.price_color' --cache-bust

# 2) 单页：ok 且 item_count ≥ 1（example.com 有文档标题，price 取不到会进 missing）
node distribution/connectors/farm-probe.js --url 'https://example.com/' --selectors title,price --cache-bust

# 3) 被拦页：blocked 且带证据原文（无代理下的 eBay 搜索页）
node distribution/connectors/farm-probe.js \
  --url 'https://www.ebay.com/sch/i.html?_nkw=usb+cable' --selectors title,price --cache-bust

# 4) 缓存反证：同一 URL 连跑两次、第二次不加 --cache-bust → error + E_CACHE_HIT（退出码 1）
#    （前提：该 profile 里已有这个 URL 的磁盘缓存；example.com 带 max-age=86000）

# 5) 预设机制：用 books.toscrape 造临时 fixture 预设 → ok 且 20 条（不碰电商站）
cat > /tmp/books-fixture.json <<'JSON'
{"id":"books-fixture","name":"fixture","search_url_template":"https://books.toscrape.com/",
 "list_selector":"article.product_pod","fields":{"title":"h3 a","price":".price_color"},
 "verified":{"list_selector":"fixture"},"notes":["机制验证"]}
JSON
node distribution/connectors/farm-probe.js --platform /tmp/books-fixture.json --cache-bust

# 6) 预设缺字段：删掉 list_selector 的 fixture → error / E_PLATFORM_INCOMPLETE / 退出码 1（不许退回单页模式）
```

预期：第 1 条 `status=ok`、`item_count ≥ 10`、退出码 `0`；第 2 条 `status=ok`、`item_count ≥ 1`、退出码 `0`；第 3 条 `status=blocked`、`evidence.matched` 非空、退出码 `2`；第 4 条 `status=error`、`error.code=E_CACHE_HIT`、退出码 `1`；第 5 条 `status=ok`、`item_count=20`、退出码 `0`；第 6 条 `status=error`、`error.code=E_PLATFORM_INCOMPLETE`、退出码 `1`。
