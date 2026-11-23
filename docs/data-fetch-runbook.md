# 取数 runbook：从拿到代理到第一页真数据

目标：一条能照抄的路径，把「网关 + 本地代理桥 + 取页探针」串起来，拿到第一页**真数据**。

边界：只读调研；不登录、不下单、不改店铺；建会话会在台账留一行（`data_retained=true`），验收前后由负责人备份清理。
令牌/代理凭据只从环境变量读，**不进 argv、不落文件、不贴聊天**。

前置两件（都在 DSH Secrets 里）：

- `GATEWAY_TOKEN`：≥32 位，`openssl rand -hex 32` 生成。
- `PROXY_URL`：**美国出口**，推荐 `socks5h://user:pass@host:port`，`http://user:pass@host:port` 也可以。

## 为什么必须走本地桥

Chromium 只认 `--proxy-server=<url>`，URL 里的 `user:pass` 它不认证（`farm/farm.js:143`）；
所以带凭据的上游要在本机起 `proxy-bridge.js`，会话指向**无凭据**的 `http://127.0.0.1:18080`，桥给上游补鉴权。

本机 DNS 是 fake-IP（`example.com → 198.18.0.37`）：上游用 `socks5h://`（远程 DNS），
`socks5://` 会把 fake-IP 交给上游，连不上。

## 0. 先跑自检（不需要真代理）

```bash
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash farm/scripts/proxy-selftest.sh --self-test
```

预期 `PASS=12 FAIL=0` / `READY` / `EXIT=0`。它用内置假上游验脚本本身，**不代表**真出口可用。

## 1. 起网关

```bash
cd farm
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash scripts/start-gateway.sh --daemon
bash scripts/start-gateway.sh --status
```

记下 `control pid=… / gateway pid=…`。`/v1/health` 免鉴权；鉴权用 `/v1/sessions` 验，无 token 必须 **401**。

## 2. 代理到手后，一条命令验通

```bash
UPSTREAM_PROXY="$DSH_SECRET_PROXY_URL" GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" \
  bash farm/scripts/proxy-selftest.sh
```

四步：桥起来且 `auth=yes` → `curl -x 桥 https://example.com/` 200 → `farm-probe` 经桥取 example.com `ok`
→ 可选 `--target-url`（默认一个 eBay 搜索页；被拦记 INFO，不算 FAIL）。

退出码：`0` 全通（再往下走）；`1` 桥或上游不通；`2` 用法/前置不满足。

## 3. 起桥（产品路径一直用它）

```bash
cd farm
UPSTREAM_PROXY="$DSH_SECRET_PROXY_URL" node proxy-bridge.js --port 18080 &
```

桥只监听 `127.0.0.1`；凭据只从环境变量读，不进 argv、不打印。验桥：

```bash
curl -x http://127.0.0.1:18080 -sS -o /dev/null -w 'bridge HTTP=%{http_code}\n' https://example.com/
```

## 4. 建会话时带 `proxy`

> `POST /v1/sessions` 和 `DELETE /v1/sessions/:id` 都**强制要求** `Idempotency-Key` 头
> （`gateway/server.js:272`、`:390`）；缺了直接 `400 E_BAD_REQUEST`，body 是
> `{"ok":false,"code":"E_BAD_REQUEST","message":"Idempotency-Key required"}`。
> 规则：**每次新建/删除都生成一个新 key；同一次请求重试必须复用同一个 key**——网关按 key 缓存响应
> （TTL 24h，`server.js:169`），复用旧 key 拿到的是上一次的结果。缓存是**进程内 Map，网关一重启就清空**，
> 所以重启后拿旧 key 重放不会命中（会当成新请求）。下面命令都用 `$(uuidgen)` 现生成。

> 网关会挡两类无效 `proxy`（都在建会话之前返回 400，报错不回显 proxy 值）：
> 带凭据 `scheme://user:pass@host:port` → `E_PROXY_CREDENTIALS`（Chromium 不认证，会悄悄直连）；
> 非 `http/https/socks5/socks5h` → `E_PROXY_SCHEME`。带账号密码的代理要写在桥的 `UPSTREAM_PROXY`，
> 会话的 `proxy` 只填桥地址 `http://127.0.0.1:18080`。
>
> 建完会话回读确认出口：`GET /v1/sessions` 每条记录都带 `proxy` 字段（直连显示 `(direct)`），
> 应当看到 `"proxy":"http://127.0.0.1:18080"`；显示 `(direct)` 说明出口没挂上。

CDP 引擎（chromium / chrome；linux150 只能 attach，不走这条）：

```bash
printf 'header = "Authorization: Bearer %s"\n' "$DSH_SECRET_GATEWAY_TOKEN" \
  | curl -sS -K - -X POST "http://127.0.0.1:19671/v1/sessions" \
      -H "Idempotency-Key: $(uuidgen)" \
      -H 'Content-Type: application/json' \
      -d '{"account":"us-amazon-1","engine":"chromium","platform":"amazon","proxy":"http://127.0.0.1:18080","headless":true}'
```

camoufox（worker 传输，proxy 变成 worker 的 `--proxy`，见 `gateway/server.js:69`）：

```bash
printf 'header = "Authorization: Bearer %s"\n' "$DSH_SECRET_GATEWAY_TOKEN" \
  | curl -sS -K - -X POST "http://127.0.0.1:19671/v1/sessions" \
      -H "Idempotency-Key: $(uuidgen)" \
      -H 'Content-Type: application/json' \
      -d '{"account":"us-amazon-cf1","engine":"camoufox","platform":"amazon","proxy":"http://127.0.0.1:18080","headless":true}'
```

链路是现成的，不用改代码：`gateway/server.js:304` 透传 `proxy` → control `/instances` →
`farm/farm.js:143`（Chromium `--proxy-server=`）/ `camoufox_worker.py:84`（worker `{'server': <proxy>}`）。

## 5. 跑探针取第一页

```bash
GATEWAY_URL=http://127.0.0.1:19671 GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" \
  node distribution/connectors/farm-probe.js \
    --platform amazon --query 'wireless+earbuds' --proxy http://127.0.0.1:18080 --cache-bust
```

- `--query` 是**原样替换** `{q}`，不做 URL 编码：空格自己写成 `+` 或 `%20`。
- `--cache-bust` 是硬要求：导航 `transferSize === 0` 会报 `E_CACHE_HIT`，那不是真取数。
- `--proxy` 填桥地址（无凭据）；把上游凭据直接写进 `--proxy` 会进 argv 且 Chromium 不认证。

## 6. 四态怎么读

退出码 `0 ok / 2 blocked / 3 empty / 1 error`：

| status | 退出码 | 判据 | 处置 |
|---|---|---|---|
| `ok` | 0 | 未拦截 + 主文档 <400 + `item_count ≥ 1` | 取 `fields`；字段真命中才回填预设 |
| `blocked` | 2 | 标题/正文/URL 命中拦截特征（**压过 items**） | 先看 `evidence.matched`，见第 7 节 |
| `empty` | 3 | 页面正常但 `item_count = 0` | 查 `container_count`：0 是选择器不对；>0 是字段选择器空（SPA 壳、懒加载） |
| `error` | 1 | 看 `error.code` | `E_GOTO` 导航失败；`E_NOT_FOUND` 主文档 404（URL 选错）；`E_CACHE_HIT` 加 `--cache-bust`；`E_PLATFORM_INCOMPLETE` 预设缺字段；`E_NO_TOKEN` 令牌没传进去 |

`container_count` 比 `item_count` 大是正常的（空卡片），比如 amazon 22 个容器 / 20 条数据。

## 7. `blocked`：先读 `matched`，再决定换什么

| `matched` 命中 | 含义 | 先做什么 |
|---|---|---|
| `robot_or_human`、`activate_and_hold`、`unusual_traffic`、`access_denied` | 出口被识别成自动化 | **换美国出口**；同一出口重试没有意义 |
| `just_a_moment`、`cf_challenge`、`px_captcha`、`verify_you_are_human` | 风控/挑战页 | 先换出口；仍出现再降频或换 camoufox 引擎 |
| `url_blocked`、`url_captcha`、`url_sorry`、`url_challenge` | 落到了拦截路径 | 先看 `final_url` 是否被重定向、入口 URL 是否选错——这类问题换出口没用 |
| `sorry`、`error_page` | 站点错误页 | 换 URL 或稍后再试；连续出现再考虑出口 |

顺序是：**读 `matched` 定性**（被什么拦）→ 看 `final_url`（URL 是否选对）→ 才决定换出口 / 换入口 / 换引擎。
不要在同一条出口上连打同一个 URL。

## 8. 产物 `verified` 怎么回填

只写两态，`distribution/verify.sh` 第 6 段会断言每个值以「命中」或「未验」开头：

- 真命中：`"命中：2026-11-23，美国出口，20/20 条，值形如 \"USD 29.99\""`（写日期、出口、条数、值的形态）
- 没跑过 / 没命中：`"未验：<原因>"`

改完跑 `bash distribution/verify.sh`（预设 schema、`id==文件名`、`verified` 前缀全在这段）。
别拿地域不对的值回填：7 站矩阵里 amazon 直连拿到的是 **JPY**，不是美元。

## 9. 没有代理时的降级

只能做这三件，不要拿直连电商站的结果当数据：

```bash
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash farm/scripts/proxy-selftest.sh --self-test  # 假上游
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash distribution/e2e-smoke.sh                   # 第 5 段本地 fixture
bash farm/scripts/test-proxy-bridge.sh                                                     # 桥的 HTTP/SOCKS5 自测
```

直连实测：amazon（日本出口）与 books 列表可用；eBay/Walmart `blocked`、Shopee `empty`、
AliExpress/Lazada `error`、tiktokshop 入口未确认——结论见 [platform-egress-matrix](platform-egress-matrix.md)。

## 10. 收尾

```bash
# 删会话（台账保留一行，data_retained=true）；DELETE 同样要 Idempotency-Key，规则见第 4 节
printf 'header = "Authorization: Bearer %s"\n' "$DSH_SECRET_GATEWAY_TOKEN" \
  | curl -sS -K - -X DELETE "http://127.0.0.1:19671/v1/sessions/default:us-amazon-1" \
      -H "Idempotency-Key: $(uuidgen)"

kill %1                                   # 停桥（或 kill 你记下的 pid）
cd farm && bash scripts/start-gateway.sh --stop
```

台账清理由负责人做：先停网关、备份 `farm/state/farm.db`、再删行，最后起回。
