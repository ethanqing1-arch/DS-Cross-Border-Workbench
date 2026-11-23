# 自建浏览器农场（不依赖紫鸟生态）

目标：用**真正的 Chrome + 独立 profile + 独立代理 + 独立时区/语言**跑多账号自动化，
不接紫鸟的 agent 模式、不申请生态 API key、不打任何 JS 指纹补丁。

---

## 1. 为什么这样设计

| 决策 | 依据（实测） |
|---|---|
| 只开 `--remote-debugging-port`，**不加** `--enable-automation` | 同样 Chrome 157：只开端口 → `navigator.webdriver=false`；加 `--enable-automation` → `true` |
| 不做 `navigator.webdriver` 补丁 | 补丁会被 `iframe.contentWindow.Function.prototype.toString.call(fn)` 反查出真实源码（实测返回 `function () { return false; }`） |
| 时区走进程 `TZ`、语言走 `--lang` | 实测 `Intl` 与 `navigator.languages` 原生生效，不需要 `Emulation.setTimezoneOverride` |
| 一账号一 `--user-data-dir` | Cookie / IndexedDB / Cache / SW 天然隔离，与 partition 不是一回事 |
| 不做 canvas/webgl 注入 | 一机多 profile 共享 GPU，注入只会引入"JS 函数"这个可反查实体 |

**已知边界**：同一台机器上的多个 profile，`canvas.hash` 与 WebGL renderer 完全相同（实测两实例 hash 均为 `e7f851c2`、renderer 均为 `Apple M5`）。平台若用 canvas/WebGL 做跨账号关联，一机多号仍会被串起来。

### 让 canvas 分叉的原生旋钮（实测）

| 启动参数 | canvas hash | WebGL renderer | 可用性 |
|---|---|---|---|
| 默认 | `e7f851c2` | ANGLE Metal / Apple M5 | 基线 |
| `--force-color-profile=srgb --disable-lcd-text` | `e7f851c2`（不变） | 不变 | ❌ 无效 |
| `--force-color-profile=display-p3` | `e7f851c2`（不变） | 不变 | ❌ 无效 |
| **`--disable-accelerated-2d-canvas`** | **`953cdf18`** | 不变（仍 Apple M5） | ✅ 可用，仅 2 档 |
| `--use-angle=swiftshader` | `b57b8e57` | **SwiftShader（明显异常）** | ❌ 不要用 |

| 隔离等级 | 做法 | 有效档位 | 适用 |
|---|---|---|---|
| L1 一机多 profile | `farm.js` 默认 | 1（canvas 全同） | 同主体多店铺、低风控 |
| L1.5 原生参数分叉 | 一半账号加 `--disable-accelerated-2d-canvas` | 2 | 需要"至少不完全一样" |
| L2 叠加多版本 | L1.5 × 2 个 Chrome 版本 | 4 | 中等要求 |
| L3 一账号一 VM | 每台一个 `farm.js` 实例 | 真正分离 | 高价值账号、支付/注册 |

---

## 2. 快速开始

```bash
cd ziniao-report/farm

# 1) 起一个账号（headful；生产不要用 --headless，见 §4）
node farm.js start --account acc01 --port 19401 --tz Asia/Tokyo --lang ja-JP

# 2) 看状态
node farm.js list

# 3) 体检（webdriver / 时区 / 语言 / canvas 稳定性 / 函数完整性 / 出口 IP）
node farm.js check --account acc01
node farm.js check --all

# 4) 停
node farm.js stop --account acc01
node farm.js stop --all
```

`start` 输出：`{ ok, account, pid, port, cdp: "http://127.0.0.1:19401", browser, tz, lang, proxy }`。

**profile 落点按平台分区**（2026-11-23 起）：`--platform amazon` → `profiles/amazon/<account>/`，不给平台 → `profiles/_unsorted/<account>/`。
这样 eBay 与 Amazon 的 cookie/指纹不混池。`--profile` 仍可显式覆盖。历史扁平目录（`profiles/<account>`）不会被新代码认领，需要保留登录态就自己挪进对应平台目录。

版本契约：`node contract.js` 看完整契约，`node contract.js check --require 1.1.0` 判版本是否满足（子模式包装机时用）。

---

## 3. 接代理

```bash
# 上游是带认证的 SOCKS5 时，先用桥把它变成无认证本地 HTTP 代理
node ../hardening/proxy-bridge.js --listen 127.0.0.1:18080 \
     --socks [PROXY_ENDPOINT]:1080 --user [PROXY_USER] --pass [PROXY_PASS]

# 实例指向桥
node farm.js start --account acc01 --port 19401 --tz America/New_York --lang en-US \
     --proxy http://127.0.0.1:18080
```

验证（本机当前无外网，需在有网环境跑）：

```bash
node farm.js check --account acc01 | python3 -c "import json,sys;d=json.load(sys.stdin)[0];print(d['probe']['ip'], d['probe']['ipErr'])"
# 期望：ip = 代理出口；ipErr 为空
```

DNS 泄漏：`sudo tcpdump -i any port 53` 同时让实例访问一个域名，观察查询是否出现在本机出口。
`--proxy-server` 用 HTTP 代理时域名交给代理解析，通常不泄漏；用 SOCKS5 时加 `--host-resolver-rules` 或直接依赖桥上解析。

---

## 4. headless 的坑（重要）

`--headless=new` 的 UA 会带 **`HeadlessChrome/157.0.0.0`**（实测），这是明确特征。

| 场景 | 建议 |
|---|---|
| 生产账号 | **headful**（默认），窗口可最小化 |
| 必须无头（服务器） | 用 `--user-agent` 覆盖 headless 标识，并同步处理 `Sec-CH-UA` 系列，否则 UA 与 client hints 不一致更显眼 |

---

## 5. 接 DS-Bot

农场只暴露一个东西：**每账号一个 CDP 端点** `http://127.0.0.1:<port>`。

```python
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.connect_over_cdp("http://127.0.0.1:19401")
    ctx = b.contexts[0]
    pg = ctx.pages[0] if ctx.pages else ctx.new_page()
    pg.goto("https://example.com")
```

注意两点（`[待实测]`）：

1. Playwright 的 `connect_over_cdp` 会注入自己的初始化脚本，页面可能残留 `__playwright*` 绑定。连接后先扫一遍：
   `Object.keys(window).filter(k => /playwright|puppeteer/i.test(k))`；有残留就改用裸 CDP（`farm.js` 里的 `cdp()` 可直接复用）。
2. Playwright 默认会 `Runtime.enable`，`debugger` 语句耗时变长可被计时探针发现。不需要事件时尽量少开域。

---

## 6. 调度与预算

| 项 | 建议 |
|---|---|
| 端口 | 19400–19499，一账号固定一个；起前 `lsof -iTCP:<port> -sTCP:LISTEN` 探活 |
| 并发 | 单机 6–10（16 GB）；每个实例 300–700 MB |
| 账号锁 | 以 `account` 为键的租约（SQLite/`flock`），同账号禁并发 |
| 失败分类 | `cdp not ready`（端口占用/启动慢）→ 换端口重试；`no state` → 未启动；`webdriver != false` → 混入了 automation 参数，拒绝上线 |
| 门禁 | 每个任务前跑 `check`，`ok=false` 直接跳过该账号 |

---

## 7. 与紫鸟的关系

- 农场**不读**紫鸟的任何配置、不调 CLI、不需要 API key。
- 若仍想复用紫鸟买到的代理出口：把 `--proxy` 指向该环境的本地入站 `http://127.0.0.1:[proxy_listen_port]`；但这会让链路重新依赖紫鸟客户端，建议直接用服务商 SOCKS5 + `proxy-bridge.js`。
- 指纹强度上，农场是"真实 Chrome + 正确时区/语言"，**没有**紫鸟那种内核级 canvas/WebGL 噪声；换来的是一致性更好、无 JS 可反查实体。

---

## 8. 故障速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `cdp not ready` | 端口被占 / profile 被锁 / Chrome 已用同一 profile 在跑 | 换端口；删 `profiles/<account>/SingletonLock`；确认无同名实例 |
| `account ... already running` | 状态文件还在且 pid 存活 | 先 `stop --account`，或换账号名 |
| `check` 报 `tz != ...` | 启动时 env `TZ` 未生效（少数版本） | 确认 `start` 用了 `--tz`；必要时改用 `Emulation.setTimezoneOverride`（会引入轻微不一致） |
| `webdriver != false` | 启动参数混入了 `--enable-automation` | 检查是否有外部脚本/IDE 注入；`farm.js` 自身不传该参数 |
| `ipErr: Failed to fetch` | 机器无外网 / 代理不通 | 先在宿主机 `curl https://api.ipify.org?format=json` 对照 |

---

## 9. 控制面（给 DS-Bot 调的 HTTP API）

```bash
node control.js --port 19555 [--token [TOKEN]] [--range 19400-19499]
```

只绑 `127.0.0.1`；带 `--token` 时所有请求需带 `x-farm-token`。

| 方法 | 路径 | 说明 | 状态码 |
|---|---|---|---|
| GET | `/health` | 台账统计 + 存活数 | 200 |
| GET | `/instances` | 账号列表（含 `alive` / `last_check_ok`） | 200 |
| POST | `/instances` | 启动；`port` 可省略自动分配 | 201 / 409 已在跑 / 500 |
| GET | `/instances/:a` | 详情 + 最近 5 次体检 | 200 / 404 |
| GET | `/instances/:a/history?limit=20` | 体检历史 | 200 |
| POST | `/instances/:a/check[?ip=1]` | 立即体检；默认跳过出口 IP（快） | 200 / 424 体检未过 |
| DELETE | `/instances/:a` | 停止并标记 stopped | 200 / 404 |

```bash
# 建实例
curl -s -X POST http://127.0.0.1:19555/instances -H 'Content-Type: application/json' -d '{
  "account":"acc01","tz":"Asia/Tokyo","lang":"ja-JP","headless":true,
  "proxy":"http://127.0.0.1:18080","store_id":"S-1001","platform":"amazon",
  "extra":"--disable-accelerated-2d-canvas"
}'
# → {"ok":true,"instance":{"port":19400,"cdp":"http://127.0.0.1:19400",...}}

# 门禁 + 留痕
curl -s -X POST http://127.0.0.1:19555/instances/acc01/check
curl -s http://127.0.0.1:19555/instances/acc01/history?limit=5
curl -s -X DELETE http://127.0.0.1:19555/instances/acc01
```

实测延迟：`check` 约 **70 ms**（跳过 IP）；带 `?ip=1` 时若网络不可达会多 3 s（fetch 超时）。

DS-Bot 侧只需两步：`POST /instances` 拿 `cdp`，然后 `connect_over_cdp(cdp)`；任务前 `POST :a/check`，`ok=false` 就跳过该账号。

---

## 10. 台账（SQLite）

`farm.db`（`node:sqlite` 内置，无第三方依赖）：

```sql
accounts(account PK, store_id, platform, port, proxy, tz, lang, extra, profile,
         headless, pid, status, created_at, updated_at, last_check_at, last_check_ok)
checks(id PK, account, at, ok, webdriver, tz, lang, canvas, renderer, ip, fails, raw)
```

```bash
node ledger.js stats                       # 账号数/在跑数/最近失败数/体检条数
node ledger.js list
node ledger.js history --account acc01 --limit 20
node ledger.js dump > export.json
```

用途：`canvas` 列能看出某天起哈希变了（客户端/系统升级）；`ip` 列能看出口漂移；`fails` 列直接当告警字段。

---

## 11. 出口链路离线验证（不需要外网）

```bash
node verify-egress.js          # 8 项检查，约 0.7 s
node verify-egress.js --json   # 机读输出
```

它起一个本地目标站 + 一个记账代理，让 Chrome 只经该代理访问**本地不可解析**的域名 `egress.test`：

| 检查 | 判据 |
|---|---|
| `cdp.ready` | `/json/version` 可达 |
| `browser.no-automation-flag` | 启动参数里没有 `--enable-automation` |
| `page.reached` | 页面拿到目标站 JSON |
| `proxy.saw-hostname` | 代理日志里出现 `egress.test`（absolute-form 带域名） |
| `dns.resolved-at-proxy` | 域名本地不可解析却访问成功 ⇒ 解析发生在代理侧 |
| `proxy.marker-injected` | 页面里出现代理注入的 `X-Egress-Proxy: farm-verify` |
| `no-direct-connection` | 目标站只被代理转发 |
| `navigator.webdriver=false` | 原生 false |

实测输出：`8/8 → PASS`。

> 有外网时再补一条真实出口比对：`POST /instances/:a/check?ip=1`，把 `ip` 与代理归属对照。

---

## 12. 裸 CDP 驱动（零框架痕迹）

```bash
node driver.js --cdp http://127.0.0.1:19401 scan
node driver.js --cdp ... goto --url "https://example.com"
node driver.js --cdp ... eval --expr "document.title"
node driver.js --cdp ... click --x 100 --y 200
node driver.js --cdp ... type --text "abc"          # insertText：无 keydown/keyup
node driver.js --cdp ... type --text "abc" --keys   # 真实按键：产生 keydown/keyup
node driver.js --cdp ... shot --path /tmp/a.png
```

`scan` 的 CLEAN 判据：`webdriver=false`、`automationKeys=[]`（扫 `__playwright*`/`__puppeteer*`/`cdc_*` 等）、`toDataURL` 与 `toString` 均为 `[native code]`。

实测（本机 Chrome 157）：`{"verdict":"CLEAN","webdriver":false,"automationKeys":[],"plugins":5,"outer":[1440,900]}`。

> 如果坚持用 Playwright 的 `connect_over_cdp`，接上后先跑一次同样扫描；出现 `__playwright*` 就说明框架注入留在页面里，改用 `driver.js`。

---

## 13. 内核替换：fingerprint-chromium（已实测跑通）

**安装**（macOS arm64，148 是最后一个有 mac 构建的版本）：

```bash
curl -LO https://github.com/adryfish/fingerprint-chromium/releases/download/148.0.7778.215/ungoogled-chromium_148.0.7778.215-1.1_macos.dmg
hdiutil attach ungoogled-chromium_148.0.7778.215-1.1_macos.dmg -nobrowse
cp -R /Volumes/Chromium/Chromium.app /Applications/fingerprint-chromium.app
xattr -dr com.apple.quarantine /Applications/fingerprint-chromium.app
# 核验：file 应显示 arm64，--version 应显示 Chromium 148.0.7778.215
```

**用法**（farm 已支持 `--chrome` / `--fp-seed`，台账新增 `engine`、`fp_seed` 两列）：

```bash
BIN=/Applications/fingerprint-chromium.app/Contents/MacOS/Chromium
node farm.js start --account fp1 --port 19431 --tz Asia/Tokyo --lang ja-JP \
  --headless --chrome "$BIN" --fp-seed 1001
```

**实测（2026-11-22，M5 arm64）**

| 账号 | 种子 | 人设 | canvas | WebGL renderer |
|---|---|---|---|---|
| fp1 | 1001 | macOS / ja-JP | `a724f43f` | Intel Iris Xe |
| fp2 | 1002 | macOS / ja-JP | `5502ca0f` | Intel Iris Xe |
| fp3 | 2001 | **Windows 10** / en-US | `a3f79f0c` | Intel UHD 620 |

- `farm dup` → `distinct_canvas: 3`、`collisions: []`
- `driver.js scan` → `CLEAN`、`webdriver:false`、`crossRealmNative:true`（内核级，不是 JS 补丁）
- `preflight --strict` → `UA=148 / CH=148`、`MacIntel / macOS`、`Win32 / Windows`、时区自洽，全 PASS
- 字体随人设走：macOS 人设探到 `PingFang/Hiragino/Menlo/Monaco`；切成 Windows 人设后只探到 `Arial`（内核把 mac 字体遮住了）

**限制**

| 限制 | 影响 | 应对 |
|---|---|---|
| 最新 150 无 macOS 构建，mac 停在 148 | 与主流 Chrome 157 差 9 个大版本，UA 版本偏旧本身是信号 | 接受；或 Linux VM 跑 150 |
| Ungoogled：无 Google 服务、无 Widevine | 依赖 Google 登录/DRM 的站点会异常 | 这类流程走真实 Chrome 或人工 |
| 每域名噪声分键 | 无（种子决定，全局一致） | 通常更好；确实需要时只能自建内核 |
| 媒体设备/语音/ClientRects 精修 | 未覆盖 | 需要更深人设时上 camoufox |

---

## 14. 多引擎路由（解决 ungoogled 的先天缺陷）

```bash
node farm.js start --account A --engine chromium ...   # fingerprint-chromium（默认）
node farm.js start --account B --engine chrome   ...   # 宿主真 Chrome（Google 服务/DRM 原生可用）
CASE=...                                                # camoufox 走 Python worker，见 §15
```

| 引擎 | 二进制 | 协议 | 适用 |
|---|---|---|---|
| `chromium` | `/Applications/fingerprint-chromium.app/...` | CDP | 指纹敏感、批量动作（默认） |
| `chrome` | `/Applications/Google Chrome.app/...` | CDP | 需要 Google 登录 / Google 服务 / 原生 DRM 的流程 |
| `camoufox` | camoufox 自带 Firefox | Playwright(Juggler) | 需要媒体设备/语音等更深人设 |

实测：`--engine chrome` 起的是 Chrome/157，canvas `e7f851c2`（未变），台账 `engine=chrome`；`--engine chromium` 是 148，种子决定 canvas。两套可同机并行，互不影响。

**路由原则**：同一账号不要跨引擎漂移（UA/引擎变了等于换人）。按账号固定引擎，写进台账 `engine` 列。

---

## 15. camoufox（Firefox 深人设）——架构差异要说清

官方注释明确：`launch_server()` **不支持 `persistent_context`**，Playwright 也无法把持久化上下文serve 成 ws 端点。所以 camoufox **没有 CDP 端点**，正确用法是「一账号一个常驻 worker，任务在 worker 内执行」。

```bash
python3 -m venv /tmp/cfx && /tmp/cfx/bin/pip install camoufox
/tmp/cfx/bin/python -m camoufox fetch          # 下载浏览器（mac.arm64 约 1.3 GB）

/tmp/cfx/bin/python camoufox_worker.py --account cf1 --profile ./profiles/ebay/cf1 \
  --tz Asia/Tokyo --lang ja-JP --headless --url https://example.com
# 输出一行 JSON：UA / webdriver / canvas / WebGL / 字体 / 语言 / 时区
```

`--engine camoufox` 在 `farm.js` 里**只登记不起进程**（写 state 与台账，`cdp: null`、`mode: "worker"`）；
任务由网关按需调 worker，所以 `CAMOUFOX_PY` 必须指向装了 camoufox 的解释器：

```bash
CAMOUFOX_PY=/tmp/cfx/bin/python node gateway/server.js --port 19671 ...
```

`/v1/tasks` 对 camoufox 支持 `goto / eval / shot / scan`，`goto` 的返回与 CDP 通道逐字相同。

**两个坑**（2026-11-23 实测）：

1. camoufox 首次启动要装 fpgen 的 pinned 模型，`ensure_fpgen_model()` 走 `github.com/.../releases/download/...`；
   在 `github.com` 连不通的网络上会卡在 `SYN_SENT → cdn-*.github.com`。可走 `api.github.com` 资产口下载同一份文件
   （`Accept: application/octet-stream`），按 `camoufox/fpgen-model.json` 的 sha256 逐个校验后写入
   `site-packages/fpgen/data/`，mtime 设 `2145916800`，再写 `.pinned-model` 戳。
2. Python **3.15** 下 fpgen 解包会报 `binascii.Error: Incomplete Base85 group`，换 **3.13** 正常；本机用 3.13 的 venv。

---

## 16. 两条限制的处理结果

### 16.1 DRM（Widevine）——已解决并实测

ungoogled 不带 CDM。把宿主 Chrome 的 CDM 拷进 profile 即可：

```bash
bash widevine.sh ./profiles/fpw
# → profiles/fpw/WidevineCdm/4.10.3112.0/{manifest.json,_platform_specific,...}
```

实测（同一实例、同一页面）：

| 状态 | `requestMediaKeySystemAccess('com.widevine.alpha')` |
|---|---|
| 装 CDM 前 | `NotSupportedError` |
| 装 CDM 后 | **`OK`** |

注意：这只解决「能建 DRM 会话」；真正播放仍需 license 服务器可达。

### 16.2 Google 服务——不做修补，做路由

ungoogled 移除了 Google API/同步，补不回来。做法是 `--engine chrome`：同一套 farm/control/ledger，换成宿主 Chrome，Google 登录与相关服务原生可用。**按账号固定引擎**，不要同一账号两边跑。

### 16.3 版本落后（148 vs 157）——实测结论：自编译目前无解

两个独立硬阻塞，都验证过：

| 阻塞 | 证据 |
|---|---|
| **本机网络** | `preflight-build.sh` → googlesource / CIPD 均 `000`（不可达），gclient 拉不到 Chromium 依赖与工具链 |
| **上游延迟发布源码** | `150.0.7871.186` 的 tag 里只有 `README/ LICENSE / qqgroup.png`；`148.0.7778.215` 才有 `patches/ utils/ chromium_version.txt` |

也就是说：**最新可构建的源码就是 148，而我们跑的就是 148**。自编译换不来新版本。

工具已就绪，环境一 GO 就能跑：

```bash
bash preflight-build.sh                       # GO / NO-GO 体检（含网络判定）
bash build-fp-chromium.sh --check 150.0.7871.186   # 源码是否已发布（现在 NO）
bash build-fp-chromium.sh 148.0.7778.215           # 完整流程（需 GO 环境）
```

**替代方案已实测跑通：Docker（Rosetta 模拟 x86_64）+ 官方 150 Linux 包**

| 项 | 实测结果 |
|---|---|
| 版本 | `Chrome/150.0.7871.186` |
| 人设 | Windows 10 / Win32 / `ja-JP` / `Asia/Tokyo`（UA-CH 与 UA 一致，preflight 全 PASS） |
| WebGL | `ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 ...)`（SwiftShader 渲染 + GPU 元数据伪造，macOS 版没有的能力） |
| 自动化痕迹 | `webdriver=false`、`crossRealmNative=true`、`scan CLEAN` |
| 多种子 | 5001 → `da9fd984`，5002 → `0c8e6821`，`dup` 零撞车 |

完整步骤见 [docker/README.md](<ziniao-report/farm/docker/README.md>)，接入用 `farm.js attach`：

```bash
node farm.js attach --account l150 --cdp http://127.0.0.1:9334 --engine linux150 \
  --tz Asia/Tokyo --lang ja-JP --seed 5001
```

代价：Rosetta 模拟下单实例内存 600–900 MB，适合验证/小批量；上量换真 x86 机器。
