# 紫鸟浏览器使用指南（macOS arm64 · 6.50.2-latest.7）

> 前提事实引自 `ziniao-report/ziniao-browser-tech-report.md`（下称「报告」），不重复论证。
> 引用标注：报告 §2.3（隔离粒度）、§3.1（指纹 schema）、§4.1（代理链路）、§5.1（can_webdriver）、§2.1（内核矩阵）、§6.2（扩展加密）。
> 标注约定：`（假设：…）` = 未验证的推断；`[待实测]` = 需在样本上跑一次确认。

---

## 一、快速开始（10 分钟跑通）

前置：`/Applications/ziniao.app` 已安装 6.50.2-latest.7，CLI 在 `~/.local/bin/ziniao`（与 app 内 `envkit/cli/darwin/arm64/ziniao` 同一二进制，107,632 B）。

```bash
# 0) 环境自检（30 秒）
/usr/bin/which ziniao && ziniao --help | head -20
# 验证：输出包含 browser / start / fix / auth / shutdown 五组子命令

# 1) 启动 GUI 并登录（首次会拉资产、生成 machineKey、下载内核）
open -a ziniao
# 验证：菜单栏出现图标；另开终端 tail 日志见 §2.1 的三行锚点

# 2) 在 GUI 里建一个环境（店铺），记下名称，例如 [STORE_NAME]
ziniao browser list --json
# 验证：JSON 中出现该店铺与其 id → 记为 [STORE_ID]

# 3) 以 agent 模式启动（实测：本版本 CLI 不接受 --remote-debug-port）
ziniao browser start --id [STORE_ID] --mode agent --json
# 验证：输出含 "Store opened" 与 "Debug port: N"（JSON 中为 data.debugPort）；没有 debugPort = 该环境未启用 CDP

# 4) 拿 CDP 端点（[DEBUG_PORT] 取自上一步）
curl -s http://127.0.0.1:[DEBUG_PORT]/json/version | python3 -m json.tool
# 验证：返回 Browser / webSocketDebuggerUrl；失败见 §五 F4

# 5) 用 Playwright 接上（二选一：CDP 直连最省事）
python3 - <<'PY'
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.connect_over_cdp("http://127.0.0.1:19222")
    ctx = b.contexts[0]; pg = ctx.pages[0] if ctx.pages else ctx.new_page()
    pg.goto("https://api.ipify.org?format=json")
    print("出口 IP:", pg.inner_text("body"))
    print("UA:", pg.evaluate("navigator.userAgent"))
    print("webdriver:", pg.evaluate("navigator.webdriver"))
    b.close()
PY
# 验证：出口 IP = 该环境代理的 IP（不是本机宽带 IP）；webdriver 为 True（agent 模式必然如此，见 §3.4）

# 6) 收尾
ziniao browser close --id [STORE_ID]
ziniao shutdown
```

> 若 `browser start` 报未登录/无环境：先在 GUI 完成登录与建环境；`--mode agent` 不跳过鉴权。

---

## 二、日常使用详解

### 2.1 安装与首次启动

**做什么**：装包、首次启动、确认内核与资产就位。

**怎么做**

```bash
# 安装（dmg）
hdiutil attach ~/Downloads/ziniao_arm64_6.50.2.7_production.dmg -nobrowse
cp -R "/Volumes/紫鸟浏览器/ziniao.app" /Applications/ && hdiutil detach "/Volumes/紫鸟浏览器"
xattr -dr com.apple.quarantine /Applications/ziniao.app   # 内部分发包如带隔离属性

# 首次启动
open -a ziniao
```

首次启动做四件事：① 生成 `machineKey`（32 B，用于加密 `app-cache/persist/`）；② 拉取 assets（当前版本号见 `ziniaoassets`，实测 `6.50.57.0`）；③ 按 `packageKernel` 下载对应内核 zip 并解压到 `env-kit/Core/`；④ 写 `~/.local/bin/ziniao`（CLI）。

**验证**

```bash
tail -50 ~/Library/Application\ Support/ziniaobrowser/logs/client/main.$(date +%Y%m%d).log \
 | grep -E "storage cipher initialized|assets directory resolved|connect kernel ipc success"
# 期望：machineKeyPresent:true / machineKeyLength:32 / selectedReason:first-run-built-in
ls -la ~/Library/Application\ Support/ziniaobrowser/env-kit/Core/
# 期望：出现 chromium_* 目录；为空 = 内核未下载（见 §五 F1）
```

**常见卡点**：`env-kit/Core/` 为空 → GUI 能开但任何环境都起不来；日志停在 `DownloadBrowserCore` 且无 `core extract failed` 反向错误，通常是网络/磁盘。排查见 §五 F1。

### 2.2 账号与环境创建

**做什么**：登录后建环境，逐项确认指纹面板。

**怎么做**：GUI → 新建环境 → 填名称/分组 → 逐项设置下表参数。面板中文名以实际 UI 为准 `[待实测]`，下表用配置字段定位（字段名来自报告 §3.1，可直接对照导出的环境 JSON）。

| 参数（配置字段） | 改它影响什么 | 什么场景该改 | 默认建议 |
|---|---|---|---|
| `ua` / `user_agent_data` | UA 串与 UA-CH（brands/platform/architecture/bitness/model/platformVersion/uaFullVersion/wow64） | 需要匹配目标站点白名单或特定系统 | 与代理国家 + 真实内核大版本对齐；**主版本必须 ≤ 内核实际版本**（5.124≈Chromium 124） |
| `time_zone` | `Intl` 时区与 `Date` 偏移 | 店铺注册地与运营地不一致 | **必改**，与代理 IP 归属时区一致 |
| `language` / `locales_chrome` / `locales_firefox` | `navigator.languages`、`Accept-Language` | 多语种站点 | 与代理国家一致，单语言即可 |
| `resolution` | `screen.*`、`avail*`、DPR、物理分辨率 | 需要匹配机型画像 | 用该平台常见值（如 1920×1080@1）；别用极端值 |
| `font` | 字体集合 | 目标是 Windows 画像却跑在 macOS | 选与 UA 平台一致的系统字体集 |
| `canvas` / `webgl_image` | 2D/WebGL 像素级噪声 | 默认开 | 开；改完务必跑 §2.6 的稳定性比对 |
| `webgl_metadata`（provider/render） | `UNMASKED_VENDOR/RENDERER` | 需要匹配显卡画像 | 与 `resolution`/机型一致；别写不存在的型号 |
| `audio_context` | AudioContext 指纹 | 默认开 | 开 |
| `client_rects` | 文本度量指纹 | 默认开 | 开（与 `font` 联动，改字体要一起改） |
| `hardware_concurrency` / `memery_device` | CPU 核数 / deviceMemory | 与机型画像不符时 | 4 或 8 / 8 |
| `media_device` | 摄像头/麦克风/扬声器 label 与数量 | 需要"无设备"或"特定设备名" | 桌面机给 1 摄像头 + 1 麦克风；服务器画像给 0 |
| `speech_voice` | `speechSynthesis.getVoices()` 列表 | 目标站点检测语音列表 | 与语言/系统匹配，别留空列表 |
| `web_gpu` | WebGPU 适配器信息 | 目标站点用 WebGPU | 与 `webgl_metadata` 一致 |
| `web_rtc`（local_ip/fake_ip） | ICE 候选中的私网/公网 IP | 强隐私场景 | 隐藏 host，`fake_ip` = 代理出口 IP 或留空 |
| `geo_location` | `navigator.geolocation` | 需要精确地理 | 与代理 IP 城市一致；`base_on_ip` 省事 |
| `do_not_track` / `bluetooth` / `battery` | 三个小 API | 极少需要 | 保持真实值（`null`/默认） |
| `port_scan_protection` | 阻断页面探测本地端口 | **默认开** | 开，且会把 `proxy_listen_port` 一并加入阻断表 |
| `os` / `vendor` | 平台画像 | 与 `ua` 联动 | 与 UA 一致，勿单独改 |
| `mixture_key` | 环境唯一键（影响噪声种子） | 不需要人改 | 由系统生成；复制环境时**必须重新生成** |

**验证**

```bash
ziniao browser list --json | python3 -m json.tool | head -40
# 期望：每个环境一条，字段可辨（id/name/group/proxy 摘要）
```

改完参数后必须做一次运行时校验：在环境里打开 `ziniao-report/probe/fingerprint-probe.html`，看 `identity` 组 `ua_vs_uach_major` 与 `platform_vs_uach` 是否为 `ok`。

### 2.3 代理配置

**做什么**：给环境绑一条出口，确认内核确实走本地入站。

**怎么做**：链路是「内核 → `http://127.0.0.1:[proxy_listen_port]`（本机无认证）→ `ziniao-gateway` → `[PROXY_ENDPOINT]`（认证在此层）」（报告 §4.1）。

| 协议（`proxyProtocolTypes`） | 填法 | 适用 |
|---|---|---|
| `http` / `https` | host、port、user、pass | 商业代理最常见 |
| `socks5` | host、port、user、pass（认证由网关代做） | 需要 UDP/更低开销 |
| `ssh` | host、port、user、pass/密钥 | 自建跳板 |
| `vless` / `v2ray` / `shadowsocks` / `rawtext` / `cdnwss` | 按服务商给的结构填 | 自建/小众线路 |
| `direct` | 无 | 本机直连调试（**别用于真实店铺**） |

来源类型（`znProxyTypes`）：`PLATFORM=1` 平台内置、`SELF=2` 自有、`LOCAL=5` 本地。

**验证**

```bash
# 1) 找到该环境的本地入站端口
lsof -iTCP -sTCP:LISTEN -nP | grep -E "ziniao|gateway|env-kit"
# 期望：出现 127.0.0.1:[proxy_listen_port]

# 2) 页面内校验出口（不是在宿主机 curl，必须走内核）
#    在环境里打开 about:blank，Console 执行：
#    fetch('https://api.ipify.org?format=json').then(r=>r.json()).then(console.log)
# 期望：ip == 该代理的出口 IP

# 3) 换国家会换参数集
ziniao browser start --id [STORE_ID] --mode agent --json
tail -20 ~/Library/Application\ Support/ziniaobrowser/logs/client/main.$(date +%Y%m%d).log | grep -i kernel
# 期望：日志里出现按 proxyCountry 取内核配置的动作（getKernelConfig）
```

**注意**：换代理国家会改变 `getKernelConfig(launchInfo, proxyCountry)` 返回的参数集，时区/语言/字体可能被联动改写——换国家后必须重跑 §2.6 的指纹基线比对。

### 2.4 内核选择与启动

**做什么**：选 Chromium 或 Firefox，启动并确认隔离。

| 维度 | Chromium 5.x（5.124 / 5.126） | Firefox 6.x（6.148） |
|---|---|---|
| 站点兼容 | 主流电商后台/广告平台 | 少数站点、需要 Firefox 画像 |
| 指纹维度 | 全（含 UA-CH、WebGPU、ClientRects） | 少 UA-CH，多走 `user.js` 偏好（`media.peerconnection.ice.*`、`geo.provider.*`、`intl.selected_languages`） |
| 自动化接入 | CDP，直接可用 | 走 Marionette/`remote.active-protocols`，DS-Bot 需另配驱动 |
| 建议 | **默认选它** | 仅当目标站点明确偏好 Firefox |

**怎么做**：环境设置里选内核类型；内核版本由 `packageKernel` 与 `env-kit/Core/` 决定，**与 app 版本独立灰度**（报告 §2.1）。

**锁定版本**（稳定性优先）

```bash
# 升级前：整机快照 + 记录当前内核与资产版本
ls ~/Library/Application\ Support/ziniaobrowser/env-kit/Core/
cat /Applications/ziniao.app/Contents/Resources/app.asar.unpacked/ziniaoassets
# 升级后：用同一环境重跑 probe，比对 canvas/webgl/audio 三项是否变化
```

`（假设：内核下载不提供官方回滚入口；可行做法是升级前对 `env-kit/Core/` 与 `app.asar` 做整目录备份，回滚时替换并断开更新源）`

**验证隔离**

```bash
ps -Ao pid,ppid,command | grep -i "user-data-dir" | grep -v grep
# 期望：每个运行中的环境一条，--user-data-dir=.../instances/userdataN
ls -la ~/Library/Application\ Support/ziniaobrowser/instances/
# 期望：目录数与同时运行的环境数一致；每个目录含 Preferences / Cache / Session Storage
```

### 2.5 多店铺运营实务

**做什么**：分组、Cookie 共享、扩展、批量启动预算。

| 项 | 做法 | 判断 |
|---|---|---|
| 环境分组 | GUI 按站点/团队建分组；`browser list --keyword [K]` 过滤 | 同组共享代理池与运维节奏 |
| Cookie 共享（`sharedCookieProfile`） | 仅在同主体多店铺需要互登时开启；实现条件是「非匿名 且 该开关=1」 | **默认关**。开了等于放弃 Cookie 隔离，关联风险最高 |
| 扩展按环境装 | 环境级 `BuiltinPluginConfig.OtherPlugin`；内置 `SBBackground` 为 `IsEssential:true` 不可禁用 | 业务插件逐环境装，别装到全局 |
| 批量启动 | 顺序启动，间隔 ≥3 s；一次 ≤5 个 | 见 §3.6 预算表 |

**验证**

```bash
ziniao browser list --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d))"
ps -Ao pid,rss,command | grep -i "user-data-dir" | awk '{s+=$2} END {print "内核总内存 MB:", s/1024}'
```

### 2.6 日常维护

**做什么**：资产热更新、缓存损坏恢复、日志巡检。

| 场景 | 操作 | 验证 |
|---|---|---|
| 资产热更新 | 正常启动即自动；版本落在 `assets-versions/<ver>/` | 日志 `assets directory resolved` 的 `selectedDir` 指向新版本 |
| 缓存解密失败 | 停客户端 → 备份并删除 `~/Library/Application Support/ziniaobrowser/app-cache/persist/__zb_assets_update_info_` → 重启重建 `[待实测]` | 日志 `persistence decrypt succeeded` 且 `isFirstRun` 重新置位 |
| 指纹跳变 | 升级前后各跑一次 probe，比 `canvas2d_hash`/`webgl`/`audioContext` | 三项中任一变化即为跳变 |
| 日志巡检 | `logs/client/main.YYYYMMDD.log`；关键行：`storage cipher initialized`、`connect kernel ipc success`、`user-data-dir detection`、`launchPrepareTrace` | — |

---

## 三、DS-Bot 自动化接入

### 3.1 接入总览

```
┌───────────────┐  ① CLI: browser start --mode agent    ┌──────────────────────────┐
│   DS-Bot      │ ───── browser start --mode agent ───► │ 紫鸟 Electron 主进程      │
│ [DS_BOT_ENTRY]│                                       │ (ziniao.app, com.ziniao.*)│
└───┬───────────┘                                       └────────────┬─────────────┘
    │                                                                │ ② spawn 内核
    │ ③ CDP: ws://127.0.0.1:[PORT]/devtools/page/<id>                ▼
    │        http://127.0.0.1:[PORT]/json/version          ┌──────────────────────────┐
    └──────────────────────────────────────────────────────►│ 内核 Chromium 5.124      │
                                                            │ --user-data-dir=…/N      │
                                                            │ --remote-debugging-port  │
                                                            │ Raw.can_webdriver=true   │
                                                            └────────────┬─────────────┘
                                                                         │ ④ 页面请求
                                                                         ▼
                                                            ┌──────────────────────────┐
                                                            │ ziniao-gateway           │
                                                            │ 入站 127.0.0.1:[P1]      │──► [PROXY_ENDPOINT]
                                                            └──────────────────────────┘
```

进程边界：DS-Bot 只与「CLI + CDP 端点」交互，不直接操作 `env-kit`/`gateway`；环境生命周期归紫鸟管，DS-Bot 只持有 `[STORE_ID] → [DEBUG_PORT]` 映射。

### 3.2 启动环境并拿到 CDP 端点

**开启方式**：`--mode agent`（对应前端 `getAgentMode()` 分支）。端口不是 CLI 参数，而是**启动响应返回**：文字模式打印 `Debug port: N`，JSON 模式为 `data.debugPort`（代码依据：内部命令 `browser.start` 的返回体含 `debugPort`）。拿到后再据此访问 `/json/version`；置 `Raw.can_webdriver=true` 的判定与端口无关，见报告 §5.1。

```bash
# 勘误（2026-11-22 实测）：本版本 CLI **没有** --remote-debug-port 参数
#   ziniao browser start --id 1 --remote-debug-port 19999
#   → Unknown argument for browser start: --remote-debug-port
# 端口来自启动响应：文字模式打印 "Debug port: N"，JSON 模式为 data.debugPort
ziniao browser start --id [STORE_ID] --mode agent --json
curl -s http://127.0.0.1:[DEBUG_PORT]/json/version
curl -s http://127.0.0.1:[DEBUG_PORT]/json/list | python3 -m json.tool | head -30
```

**token**：`Raw.cdp_token = browserToken`，仅在 `webDriverConfig.fromZclaw` 为真时注入（云控发起）。本地 `--mode agent` 是否也注入 `[待实测]`。若返回 401/403：

```bash
# 候选一：查询参数
curl -s "http://127.0.0.1:[DEBUG_PORT]/json/version?token=[CDP_TOKEN]"
# 候选二：请求头
curl -s -H "Authorization: Bearer [CDP_TOKEN]" http://127.0.0.1:[DEBUG_PORT]/json/version
# 候选三：WebSocket 握手时带（浏览器端不支持自定义头，故多为 query）
```

`[CDP_TOKEN]` 取值：环境启动返回值里的 `browserToken`，或日志中 `kernel_ext` 的 `browser_token` `[待实测]`。

**验证**：`/json/version` 返回 `{"Browser": "...Chrome/1xx...", "webSocketDebuggerUrl": "ws://..."}`；`/json/list` 的 `type=page` 即目标页。

### 3.3 DS-Bot 侧对接清单

| # | 接口 | 必须实现 | 输入 | 输出 | 失败语义 |
|---|---|---|---|---|---|
| 1 | 环境枚举 | 是 | — | `[{store_id, name, group}]` | 空列表 → 阻断启动 |
| 2 | 环境启动 | 是 | `store_id`, `debug_port`, `mode=agent` | `{ok, pid?, cdp_http, browser_token?}` | 区分「未登录/环境不存在/内核未下载/端口占用」 |
| 3 | 环境关闭 | 是 | `store_id` | `{ok}` | 幂等，重复关闭不报错 |
| 4 | CDP 连接管理 | 是 | `cdp_http` 或 `ws_url` | 会话句柄 | 5 s 超时 + 2 次重连 |
| 5 | 页面动作层 | 是 | 会话 + 动作 DSL | 结果/DOM 快照 | 动作级重试 ≤2 |
| 6 | 代理健康检查 | 是 | `store_id` | `{egress_ip, country, asn}` | 与期望不符 → 不派任务 |
| 7 | 指纹快照 | 是 | 会话 | probe JSON | 与基线不一致 → 标记环境异常 |
| 8 | 任务队列/环境锁 | 是 | `store_id` | 独占租约 | 同环境并发 = 拒绝 |
| 9 | 日志与指标上报 | 是 | — | JSONL/SQLite | 本地兜底落盘 |

配置样例（占位符，按此结构填）：

```json
{
  "ziniao": {
    "cli": "/Users/[USER]/.local/bin/ziniao",
    "app": "/Applications/ziniao.app",
    "log_dir": "/Users/[USER]/Library/Application Support/ziniaobrowser/logs/client",
    "debug_port_range": [19000, 19999],
    "start_timeout_s": 90,
    "close_timeout_s": 30
  },
  "ds_bot": {
    "entry": "[DS_BOT_ENTRY]",
    "concurrency": 5,
    "cdp": { "connect_timeout_ms": 5000, "reconnect": 2, "keep_alive_s": 0 },
    "proxy_check": { "url": "https://api.ipify.org?format=json", "expect_country": "[COUNTRY]" },
    "fingerprint_baseline": "fingerprints/[STORE_ID].json",
    "retry": { "max": 3, "backoff_s": [5, 20, 60] },
    "storage": { "metrics": "var/metrics.jsonl", "tasks": "var/tasks.sqlite" }
  }
}
```

### 3.4 指纹一致性保持（`can_webdriver=true` 的代价与补偿）

agent 模式下必然置位 `can_webdriver`，带来四处可检出痕迹：

| # | 检出点 | 机制 | 平台侧怎么用 |
|---|---|---|---|
| D1 | `navigator.webdriver === true` | 内核自动化开关的直接产物 | 一行 JS 即可判定 |
| D2 | CDP `Runtime.enable` 副作用 | `debugger` 语句阻塞变长、console 序列化差异 | 计时探针（`performance.now()` 前后差） |
| D3 | 注入脚本留痕 | `Page.addScriptToEvaluateOnNewDocument` 的脚本若未伪装 `toString`/描述符，`Function.prototype.toString` 直接抓 | 函数完整性检查 |
| D4 | 调试端口暴露 | 端口对**本机进程**可见；网页侧只能做 side-channel（`fetch` 到 `127.0.0.1` 的错误类型/时序，受 PNA 限制） | 本机对抗为主 |

**补偿位置与做法**

| 位置 | 做法 | 代价 |
|---|---|---|
| A. 启动参数 | 只用 `--mode agent`，不要再叠加 `--enable-automation`（客户端已按需处理） | 无 |
| B. 页面加载前（**主战场**） | `Page.addScriptToEvaluateOnNewDocument` 注入、`document_start` 前生效；必须复刻描述符形态（`Navigator.prototype` 上的 accessor、`configurable:true`、无 setter） | 需过 detect-hook 的 T1/T2b |
| C. 连接层 | 只在任务窗口连 `Runtime`，任务结束 `Target.detachFromTarget` 并断开；不常驻 `Runtime.enable` | 缺实时事件，需轮询 |
| D. 端口层 | 保持只绑 `127.0.0.1`；远端接入用 `ssh -L [DEBUG_PORT]:127.0.0.1:[DEBUG_PORT] [HOST]`，禁止 `0.0.0.0` | 多一跳 |

B 的最小实现（必须配合 `toString` 伪装，否则 §6.5 的 T2b 直接命中）：

```python
# Playwright 侧注入
INJECT = r"""
(() => {
  const origTS = Function.prototype.toString;
  const native = new WeakMap();
  const mark = (fn, name) => {
    try { Object.defineProperty(fn, 'name', { value: name, configurable: true }); } catch (e) {}
    native.set(fn, 'function ' + name + '() { [native code] }');
    return fn;
  };
  const getter = mark(function () { return false; }, 'get webdriver');
  Object.defineProperty(Navigator.prototype, 'webdriver', {
    get: getter, configurable: true, enumerable: true
  });
  const patchedTS = mark(function toString() {
    const s = native.get(this);
    return typeof s === 'string' ? s : origTS.call(this);
  }, 'toString');
  native.set(patchedTS, 'function toString() { [native code] }');
  Object.defineProperty(Function.prototype, 'toString', { value: patchedTS, configurable: true });
})();
"""
page.add_init_script(INJECT)     # 必须早于任何 goto
```

**验证**

```python
print(page.evaluate("navigator.webdriver"))                    # 期望 False
print(page.evaluate("Function.prototype.toString.call(Function.prototype.toString)"))
# 期望 "function toString() { [native code] }"
# 再把 ziniao-report/poc/detect-hook.js 注入页面跑一遍：score 应 < 25（CLEAN）
```

> 注意：补偿只解决 D1/D3；D2 靠连接策略（C），D4 靠端口策略（D）。四者缺一不可。

### 3.5 代理链路验证（从 DS-Bot 侧）

```python
# 1) 页面级出口校验（不是宿主机 curl）
ip = page.evaluate("fetch('https://api.ipify.org?format=json').then(r=>r.json())")
assert ip["ip"] == EXPECT_EGRESS_IP, ip
# 2) DNS：用页面请求一个自建权威域（[DNS_PROBE_DOMAIN]），对照权威日志的来源 IP
page.goto("http://[DNS_PROBE_DOMAIN]/")
# 3) JA3 对照：宿主机侧跑（说明：此命令验的是代理链路，不是内核）
#    python3 scripts/ja3_compare.py --proxy http://127.0.0.1:[PROXY_ENDPOINT_PORT] --impersonate chrome124
```

**内核 JA3** 只能从抓包得到：`sudo tcpdump -i any -n -s0 -w /tmp/zn.pcap "tcp port 443"`，再用 `tshark -r /tmp/zn.pcap -Y "tls.handshake.type==1" -T fields -e tls.handshake.ja3`。期望：JA3 与内核大版本匹配、且与 `navigator.userAgent` 声称的版本一致。

自建桥复现（不走紫鸟代理时）：

```bash
node scripts/proxy-bridge.js --listen 127.0.0.1:18080 \
     --socks [PROXY_ENDPOINT]:1080 --user [PROXY_USER] --pass [PROXY_PASS]
# 验证：curl -x http://127.0.0.1:18080 https://api.ipify.org?format=json 返回代理出口 IP
```

### 3.6 批量调度

| 项 | 预算（假设：单机 16 GB / 8 核） | 说明 |
|---|---|---|
| Electron 主进程 | 300–600 MB | 只 1 个 |
| 每个 Chromium 环境 | 350–700 MB（browser+gpu+renderer+utility） | 页面多/重站点取上限 |
| 每个 Firefox 环境 | 300–600 MB | — |
| 每环境 gateway | 20–50 MB | 常驻 |
| 建议并发 | 5–8（16 GB）/ 12–16（32 GB） | 超过即 swap，CDP 超时率上升 |

- **端口分配**：`[19000, 19999]` 窗口取空闲端口，分配前 `lsof -iTCP:[PORT] -sTCP:LISTEN` 探测；一个环境固定一个端口，复用前先 `browser close`。
- **失败分类与重试**：`环境不存在`（不重试）｜`未登录/无权限`（不重试，告警）｜`内核未下载`（重试 1 次并触发 `fix startup`）｜`端口占用`（换端口立即重试）｜`代理不通`（换线路后重试，≤2）｜`内核崩溃`（重启环境，≤1）。
- **环境锁**：以 `[STORE_ID]` 为键的租约（SQLite `BEGIN IMMEDIATE` 或文件锁 `flock`），租约超时 = `start_timeout + 任务上限`，超时自动释放并记事件。

### 3.7 可观测性

| 指标 | 采集点 | 存储 |
|---|---|---|
| 内核启动耗时 | 启动前后 `time.monotonic()`；对照日志 `launchPrepareTrace` | JSONL |
| CDP 连接成功率/耗时 | 连接层 | JSONL |
| 代理失败率 | 出口校验结果 | JSONL |
| 指纹快照 | 每环境首次任务后跑一次 probe | `fingerprints/[STORE_ID].json` |
| 环境异常事件 | 重试分类 | SQLite |
| 二进制/内核版本 | `cat ziniaoassets` + `ls env-kit/Core/` | 每日一条 |

与审计脚本串联：`APP=/Applications/ziniao.app bash scripts/asar-audit.sh` 每日跑一次，比对 `evidence/fuses.txt` 与 `evidence/package.json` 的 sha256/版本；变化即视为客户端被静默升级，暂停批量任务并重跑指纹基线。

---

## 四、场景对照表

| 场景 | 先看 | 再看 | 关键注意点 |
|---|---|---|---|
| 指纹对抗研究 | §2.2 参数面板 | §2.6 稳定性比对、报告 §3.1/§3.3、`probe/fingerprint-probe.html` | 每次只改一个维度；改完必须三次重启比对；`mixture_key` 是噪声种子 |
| 自动化/爬虫接入 | §一、§3.2 CDP | §3.4 补偿、§3.6 调度 | `can_webdriver=true` 是硬伤，D1/D3 必须补偿，D2/D4 靠连接与端口策略 |
| 安全审计 | §2.1 首次启动 | 报告 §6.2、`scripts/asar-audit.sh`、扩展解包 | 只读样本；fuses 与 asar 完整性决定"能不能改"，先记录再动手 |
| 日常多店铺运营 | §2.5 多店铺 | §2.3 代理、§2.4 内核选择 | Cookie 共享默认关；换代理国家 = 换参数集，必须重跑基线 |

---

## 五、故障排查速查表

| 症状 | 可能原因 | 验证命令 | 处理 |
|---|---|---|---|
| F1 环境起不来，`env-kit/Core/` 为空 | 内核未下载（首启网络中断/磁盘满） | `ls ~/Library/Application\ Support/ziniaobrowser/env-kit/Core/`；`grep -E "DownloadBrowserCore|core extract failed" ~/Library/Application\ Support/ziniaobrowser/logs/client/main.$(date +%Y%m%d).log` | `ziniao fix startup --auto-allow`；仍失败则清 `env-kit/log_data` 后重启客户端 |
| F2 biz ipc 连接失败 | `env-kit` 进程未起/被杀/版本不匹配 | `ps aux \| grep env-kit`；`grep -E "connect to biz ipc error|connect kernel ipc success" …main.log` | 退出客户端 → `ziniao shutdown` → 重启；仍失败检查 `env-kit` 是否被 EDR 拦截 |
| F3 代理不通 | 上游认证失败/线路失效/本地入站未监听 | `lsof -iTCP -sTCP:LISTEN -nP \| grep gateway`；页面内 `fetch('https://api.ipify.org?format=json')` | 换线路；核对 `InboundInfo` 的 user/pass；确认 `NoProxyList` 未把目标域放直连 |
| F4 CDP 连不上 | 未用 `--mode agent` / 该环境未返回 `debugPort` / 仅监听 127.0.0.1 而客户端在别处 / 需 token | `python3 hardening/dsbot_adapter.py ports`；`curl -s http://127.0.0.1:[DEBUG_PORT]/json/version` | 看启动响应有无 `data.debugPort`；无则改用 9481 zclaw 或 WS 控制；401 时按 §3.2 试 token |
| F5 缓存解密失败 | `machineKey` 变更（换机/换用户/重装） | `grep -E "persistence decrypt|machineKeyPresent" …main.log` | 备份并删除 `app-cache/persist/__zb_assets_update_info_` 后重启 `[待实测]` |
| F6 端口占用 | 上次未 `browser close`/端口窗口冲突 | `lsof -iTCP:[PORT] -sTCP:LISTEN -nP` | 关掉占用进程或换端口；调度器加端口探活 |
| F7 内核崩溃/白屏 | 内核版本与 app 灰度不匹配 | `ls env-kit/Core/`；`grep -E "BrowserExitWithError|recover" …main.log` | 删对应内核目录重下；或回滚 `env-kit/Core/` 快照 |
| F8 指纹跳变 | 资产/内核热更新 | 升级前后 probe `canvas2d_hash` 比对 | 暂停该环境接单；按 §2.6 重建基线 |
| F9 扩展未加载 | 扩展包解密失败/被安全软件拦截 | `ls app.asar.unpacked/assets/extensions/`；`grep -i "UnzipExtensionFromCrx" …main.log` | 重装客户端；确认 `SBBackground.zip` 未损坏 |

---

## 六、待实测项

| # | 项 | 怎么测 | 影响 |
|---|---|---|---|
| 1 | GUI 参数面板的中文名与字段对应 | 建环境后导出环境 JSON，与报告 §3.1 字段逐一比对 | §2.2 表格落地 |
| 2 | 本地 `--mode agent` 是否注入 `cdp_token` | 启动后看 `/json/version` 是否 401；查日志 `cdp_token`/`browser_token` | §3.2 连接方式 |
| 3 | token 的传输形态（query/header/ws 子协议） | 三种方式各试一次，记录成功者 | DS-Bot 连接层实现 |
| 4 | `--mode agent` 是否等价于 `--enable-automation` | 比对 `navigator.webdriver` 与 `plugins.length`、`window.outerHeight` | D1 的补偿必要性 |
| 5 | 定制内核是否保留"受自动化控制"提示条 | 目视 + 截图对比原生 Chromium | 视觉层可检出性 |
| 6 | 内核下载域名与端口 | 首次启动抓包（`tcpdump -i any -n port 443`）过滤大文件 | 版本锁定/离线部署方案 |
| 7 | `env-kit/Core/` 回滚是否被接受 | 备份后替换目录，启动看是否重建 | 版本锁定可行性 |
| 8 | 删除 `__zb_assets_update_info_` 的恢复行为 | 备份→删除→重启，看是否重建 | §2.6 恢复流程 |
| 9 | `--headless` 对指纹的影响 | 同一环境 headful/headless 各跑 probe 比对 | 批量场景选型 |
| 10 | Firefox 内核的 CDP 等价通道 | 启动后看 `remote.active-protocols` 与端口 | DS-Bot 是否支持 Firefox |
| 11 | 单环境真实内存峰值 | `ps -Ao pid,rss,command` 采样 5 分钟 | §3.6 并发预算 |
| 12 | `ziniao browser list --json` 的完整字段 | 实跑并保存样例 | 调度器建模 |
