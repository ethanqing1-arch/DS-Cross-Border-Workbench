# 代理桥 runbook（`farm/proxy-bridge.js`）

**它解决什么**：Chromium 的 `--proxy-server` 只认一个 URL，不认 URL 里内嵌的 `user:pass`
（`farm/farm.js:143` 原样写入），所以带账号密码的上游代理直接不生效。桥把「带凭据的上游」
包成「无凭据的本地代理」：会话只指向 `http://127.0.0.1:18080`，由桥向上游注入
`Proxy-Authorization: Basic ...`。

```
farm_session_create(proxy=http://127.0.0.1:18080)  ← argv/台账里没有凭据
      → proxy-bridge.js:18080 → 注入 Proxy-Authorization → 上游代理 → 目标站
```

## 0. 前置

- `node` 在 PATH 里（非登录 shell 先 `export PATH="/opt/homebrew/bin:$PATH"`）。
- 网关在跑：`bash farm/scripts/start-gateway.sh --status`（应看到 `control: up` / `gateway: up`）。
- 上游代理已开通，且知道它的 **host:port、账号、密码**。

## 1. 起桥

```bash
# HTTP 上游（Basic 认证）
export UPSTREAM_PROXY='http://user:pass@host:port'   # 只走环境变量
node farm/proxy-bridge.js --port 18080

# SOCKS5 上游：socks5h 让代理端解析域名（推荐）
UPSTREAM_PROXY='socks5h://user:pass@host:1080' node farm/proxy-bridge.js --port 18080

# SOCKS5 本地解析（bridge 自己把域名解析成 IPv4 再按 IP 连）
UPSTREAM_PROXY='socks5://user:pass@host:1080' node farm/proxy-bridge.js --port 18080
```

后台常驻：

```bash
export UPSTREAM_PROXY='http://user:pass@host:port'
nohup node farm/proxy-bridge.js --port 18080 >/tmp/proxy-bridge.log 2>&1 &
echo $! > /tmp/proxy-bridge.pid
```

- 启动日志只有一行（**不含凭据**）：
  `[proxy-bridge] listen 127.0.0.1:18080 -> upstream socks5h host:port auth=yes`
  （`http` / `socks5` / `socks5h` 三种上游都会标出来）
- `--upstream 'http://user:pass@host:port'` 也能起，但**凭据会出现在 `ps` 里**（脚本会打一行警告）；
  生产只用 `UPSTREAM_PROXY`。
- 密码里出现 `@ : / ? #` 等字符必须 percent-encode：`p@ss` → `p%40ss`。
- **`socks5h://` 与 `socks5://` 的区别（重要）**：
  - `socks5h://`：**域名交给上游解析**（远程 DNS）。生产用这个。
  - `socks5://`：bridge 先本地解析成 IPv4，再把 IP 交给上游。本机 DNS 是 fake-IP
    （实测 `example.com → 198.18.0.37`，由 `198.18.0.2#53` 应答），这类 IP 只有本机
    代理客户端认识，**远端 SOCKS5 服务器连不上**——所以真代理一律用 `socks5h://`。
- SOCKS5 认证走 RFC 1929（用户名密码）；上游没配凭据时只报 NO AUTH。
- 停：`kill "$(cat /tmp/proxy-bridge.pid)"`（SIGTERM，正常退出 0）。

## 1.5 拿到代理先跑这条（一条命令验通）

`farm/scripts/proxy-selftest.sh` 自动挑空闲端口起桥，按四步验到「探针真能经桥取数」，收尾自己停桥、清临时文件、扫凭据。

```bash
export PATH="/opt/homebrew/bin:$PATH"
export UPSTREAM_PROXY='socks5h://user:pass@host:1080'   # 凭据只走环境变量，别写进命令行
GATEWAY_TOKEN=... bash farm/scripts/proxy-selftest.sh
```

```bash
# 换目标站（默认一个 eBay 搜索页）
bash farm/scripts/proxy-selftest.sh --target-url 'https://www.ebay.com/sch/i.html?_nkw=usb+cable'

# 没有真代理：用内置假上游把四步走一遍，证明脚本本身是对的
GATEWAY_TOKEN=... bash farm/scripts/proxy-selftest.sh --self-test
```

四步含义与判定：

| 步骤 | 判据 | 失败时 |
|---|---|---|
| 1 起桥 | 日志出现 `listen 127.0.0.1:<port> ... auth=yes`（上游带账号密码时必须 `auth=yes`；无凭据则 `auth=no`） | `FAIL`，退出码 1 |
| 2 curl | `curl -x 桥 https://example.com/` → `HTTP 200` | `FAIL`，退出码 1 |
| 3 探针 | `farm-probe --proxy 桥 --cache-bust` 取 example.com → `status=ok` 且 `item_count ≥ 1` | `FAIL`，退出码 1 |
| 4 目标站 | 默认 eBay 搜索页：`ok`=PASS / `blocked`=**INFO（如实报，不算 FAIL）** / `empty`=WARN / `error`=WARN | 不影响退出码 |

- 退出码：`0` 全通（第 4 步被拦也算全通）；`1` 桥或上游不通（1–3 有 FAIL、或凭据泄漏）；`2` 用法/前置不满足（缺 `UPSTREAM_PROXY` / `GATEWAY_TOKEN` / 网关不可达）。
- 第 4 步 `blocked` **不是失败**：它说明出口能通、只是目标站反爬；要换出口或登录态，别去改桥。
- `--self-test` 的内置假上游会给 `robot-wall.test` 返回一页 `Robot or human?`，专门验证「blocked 记 INFO」这一支；但它需要本机能直连 `example.com`（假上游真转发），且**不代表真代理出口可用**。
- 收尾会 `grep` 桥日志、探针输出、curl stderr、假上游记录，凭据命中数必须是 0；`--keep-tmp` 可保留临时目录排查。
- 输出里的 token 长度 `WARN`（<32）照跑，但按群规该换成 `openssl rand -hex 32`。

## 2. 先自检桥（不依赖目标站）

```bash
curl -s -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:18080 https://example.com/
```

| 结果 | 含义 | 下一步 |
|---|---|---|
| `200` | 桥 + 上游都通 | 可以走第 3 步 |
| `000` | 桥没起 / 端口不对 | 看 `/tmp/proxy-bridge.log` 与 `lsof -nP -iTCP:18080 -sTCP:LISTEN` |
| `407` | 上游拒了凭据 | 第 5 节排查 |
| `502` | 桥连不上上游，或 SOCKS 握手/认证失败 | host:port 写错 / 上游要白名单 / SOCKS 账号密码错（看桥日志里的 `socks 认证失败`） |

## 3. 探针走桥

```bash
node distribution/connectors/farm-probe.js \
  --url 'https://www.ebay.com/sch/i.html?_nkw=usb+cable' \
  --selectors title,price \
  --cache-bust \
  --proxy http://127.0.0.1:18080
```

- 会话侧只带 `http://127.0.0.1:18080`（**没有凭据**）；探针输出只报 `proxy_set: true`，
  代理值不进 JSON/日志/错误文本。
- `--cache-bust` 会追加唯一 `_cb` query：不加时命中磁盘缓存会被判 `E_CACHE_HIT`（退出码 1），
  因为缓存页没有真正取数。
- 判定：`ok`（退出 0）/ `blocked`（2，带 `evidence.matched` 与 `body_snippet`）/
  `empty`（3）/ `error`（1）。

## 4. 没有真代理时：假上游自测

不需要真代理，用一个自带 Basic 校验、记录是否收到头、真转发到 example.com 的假上游，
同时验 curl 两条路径与真实浏览器产品路径：

```bash
GATEWAY_TOKEN="换成你的令牌" bash farm/scripts/test-proxy-bridge.sh
```

预期：`PASS=16 FAIL=0` / `RESULT: READY` / `EXIT=0`。覆盖：

- 假上游要求 `Proxy-Authorization`，缺失/错误一律 407；
- curl `-x` 走 `https`（CONNECT 隧道）与 `http`（绝对 URI）都 200；
- MCP `farm_session_create(proxy=桥)` → `farm_task goto` → `farm_session_delete`，
  浏览器那一路也让假上游收到鉴权头（`CONNECT 次数 1 → 2`）；
- 上游密码随机生成、只走 `env` 传子进程，输出里 grep 不到；token 不进 argv。

可选参数：`--port 18080`（桥端口）、`--upstream-port 18581`（假上游端口）。

## 5. 407 与常见故障排查顺序

1. **桥起来没有**：`curl -x` 返回 `000` → 查进程与端口（`lsof -nP -iTCP:18080 -sTCP:LISTEN`）。
2. **407**：上游拒了凭据。
   - 账号/密码是否过期；
   - 密码是否 percent-encode（`@`→`%40`、`:`→`%3A`、`/`→`%2F`）；
   - 上游是否要求 IP 白名单/绑定设备（换一台上游会 407）。
3. **502 / 卡住**：桥连不上上游。核对 `host:port`、上游是否只开给特定 IP、本机 DNS。
   SOCKS5 还要看桥日志里的具体原因：`socks 认证失败`（账号密码错）、
   `socks CONNECT 失败：connection refused`（上游连不到目标）、`socks 握手超时`（上游不通/端口错）。
4. **页面是 SORRY / Error Page / captcha**：桥通了但**出口被判**，不是桥的问题；
   换 IP/住宅代理。探针会返回 `blocked` 并附原文，不会混成 `empty`。
5. **报 `E_CACHE_HIT`**：这次导航来自磁盘缓存（`transferSize === 0`），没真取数。
   加 `--cache-bust` 或换 URL 重跑。
6. **看日志**：桥只打 `host:port` 与 `auth=yes/no`，**永不打凭据**；不要为了排查把
   `UPSTREAM_PROXY` 打进日志。

## 6. 边界（当前实现）

- 上游支持 `http://`、`socks5://`、`socks5h://` 三种；SOCKS5 认证为 RFC 1929（用户名密码），
  未配置凭据时走 NO AUTH。socks 上游**必须显式带端口**，缺端口/坏格式会拒绝启动（`exit 2`）。
- 生产优先 `socks5h://`（远程 DNS）；`socks5://`（本地解析）在本机 fake-IP 环境下会把
  `198.18.0.x` 这样的地址交给上游，远端代理连不上。
- 只监听 `127.0.0.1`，本机进程可无鉴权使用；不对外网开放。
- 支持 CONNECT（https）与绝对 URI（http）；不做缓存、不做限速、不重试。
- 上游凭据只在环境变量里，不出现在日志/JSON/错误文本；浏览器 argv 里会出现
  `--proxy-server=http://127.0.0.1:18080`（无凭据，farm 层行为）。
- **没有真代理时**，第 4 节只能证明「桥—对话链—浏览器」这条链路正确，
  不能证明出口可用；出口是否被判只有真代理能验。
- 退出码：`0` 正常停止；`1` 监听失败（端口被占）；`2` 配置错误（上游缺失/格式错/不支持协议/socks 缺端口）。

## 7. 相关文件

| 文件 | 作用 |
|---|---|
| `farm/proxy-bridge.js` | 桥本体（零依赖） |
| `farm/scripts/test-proxy-bridge.sh` | 假上游 + curl + 真实浏览器产品路径自测 |
| `farm/scripts/proxy-selftest.sh` | 拿到代理后一条命令验通（四步 + 收尾）；`--self-test` 无真代理也能验脚本 |
| `farm/scripts/acceptance.sh` | 收编桥：文件清单、`node --check`、无上游/坏上游拒绝启动的静态检查 |
| `distribution/connectors/farm-probe.js` | 取页探针；`--proxy` 指向桥，`--cache-bust` 防缓存假绿 |
