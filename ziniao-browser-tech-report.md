# 紫鸟浏览器（ZiNiao / SuperBrowser）技术调研报告

> 分析基准：macOS arm64 客户端 `6.50.2-latest.7`（包标识 `com.ziniao.fzzixun`），
> 隔离虚拟机内只读分析，无真实第三方账号参与。
> 证据等级：**[已验证]** = 本次在样本上实测/实测代码路径；**[静态推断]** = 由代码或二进制结构推理，未运行时验证；**[公开资料]** = 厂商文档/第三方横评，版本相关、易漂移。

---

## 一、执行摘要

紫鸟浏览器是「Electron 30.5.1 外壳 + 自研双内核（Chromium 5.x / Firefox 6.x）+ 三个 Go 常驻进程」的分层架构：Electron 只做 UI 与编排，指纹伪造发生在**内核层**而非 JS 注入层——环境配置以结构化 JSON（`EnvironmentData.Detail.advanced`）下发，覆盖 UA-CH、Canvas、WebGL、Audio、字体、ClientRects、WebRTC、媒体设备、语音、端口扫描防护等 20+ 维度，Firefox 侧落到 `user.js` 偏好项，Chromium 侧落到内核 `Raw`/命令行开关。隔离粒度是**每环境一个完整 `user-data-dir`**（`instances/userdataN`），不是共享 profile 的 partition。代理由 sing-box 派生的 `ziniao-gateway` 承担，支持 direct/socks5/sslvpn/ssh/v2ray/vless/shadowsocks/http(s) 等 13 种协议，以「本地入站代理 + 上游认证」模式绕开 Chromium 不支持 SOCKS5 认证的限制。安全侧做了三件事：asar 完整性校验 + `OnlyLoadAppFromAsar`、vendor 代码 bytenode 字节码化、扩展包 ZipCrypto 加密；但扩展口令**硬编码在主进程 bundle** 中，实测可直接解包，这是本地攻击面。自动化模式下内核会置 `can_webdriver=true` 并开放 `--remote-debugging-port`（带 `cdp_token`），此时 `navigator.webdriver` 与 CDP 痕迹可被平台直接检出。

---

## 二、产品与架构分析

### 2.1 客户端形态与版本矩阵

| 项目 | 值 | 证据 |
|---|---|---|
| 外壳 | Electron 30.5.1（对应 Chromium 124） | `Frameworks/Electron Framework.framework` 的 `CFBundleVersion=30.5.1` **[已验证]** |
| 包标识 / 版本 | `com.ziniao.fzzixun` / `6.50.2-latest.7` | `Info.plist` **[已验证]** |
| 架构 | arm64 单架构（Windows 侧另发 x64/x86 包） | `file` 输出 **[已验证]** |
| 更新通道 | Squirrel + `electron-updater`，feed：`https://superbrowser-web.s3.cn-north-1.amazonaws.com.cn/electron` | `Resources/app-update.yml` **[已验证]** |
| 深链协议 | `superbrowser://`、`superbrowserv6://` | `CFBundleURLTypes` **[已验证]** |
| 原生依赖 | `better_sqlite3.node`、`@jellybrick/ffi-napi`（FFI 调用系统 API） | `app.asar.unpacked/addon`、`package.json` **[已验证]** |

**双内核**（`package.json → packageKernel`，**[已验证]**）：

| 平台 | Chromium 内核 | Firefox 内核 |
|---|---|---|
| win32 x64 | `chromium_win64_202410291054_ver5.126.1.0.110.zip` | `firefox_win64_202609011231_ver6.148.1.0.12.zip` |
| darwin arm64 | `chromium_arm64_ziniaobrowser_202406061741_ver5.124.1.2.21.zip` | `firefox_arm64_ziniaobrowser_202609031812_ver6.148.1.0.37.zip` |
| darwin x64 | `chromium_mac_ziniaobrowser_202406061405_ver5.124.1.2.20.zip` | `firefox_mac_ziniaobrowser_202609031810_ver6.148.1.0.4.zip` |
| linux x64 | `chromium_linux_202402231005_ver5.120.1.0.14.zip` | — |

内核不随 Electron 打包，而是**运行时按版本下载 zip 并解压**（`env-kit` 中的 `DownloadBrowserCore`、`core extract failed`、`Get latest core version` 字符串）**[已验证]**。这意味着内核可独立灰度更新——版本漂移是最大的稳定性风险来源（见第八节）。

### 2.2 进程与 IPC 模型

```
┌─────────────────────────────┐
│ Electron 主进程 (main.index.js)│  UI、环境 CRUD、启动编排、账号/云端同步
│  · 拒绝 --remote-debugging-port│
│  · 组装 EnvironmentData / Raw │
└───────┬──────────────┬───────┘
        │ biz ipc      │ child_process
        ▼              ▼
┌───────────────┐  ┌──────────────────────────────┐
│ env-kit (Go)  │  │ 内核进程（Chromium/Firefox） │
│ 内核下载/解压 │  │  · --user-data-dir=instances/N│
│ 容器目录/配置 │  │  · --remote-debugging-port=N  │
│ Cookie 同步   │  │  · 扩展 SBBackground (MV3)    │
│ CRX 安装      │◄─┤  · chrome.superbrowser 私有API│
└───────┬───────┘  └──────────────────────────────┘
        │ 本地 HTTP/SOCKS 入站
        ▼
┌───────────────────────────┐   ┌──────────────────────┐
│ ziniao-gateway (sing-box) │──►│ 上游代理 [PROXY_ENDPOINT] │
│ 13 种协议 + 国内直连分流   │   └──────────────────────┘
└───────────────────────────┘
┌───────────────────────────┐
│ z-tracking-client (埋点)   │
└───────────────────────────┘
```

- Electron 与内核管理器之间是自定义 **biz ipc**（`connect to biz ipc error` / `connect kernel ipc success`）**[已验证]**。
- 内核与扩展之间是私有扩展 API：`chrome.superbrowser.runExtension` / `showModalWebViewDialog` / `onClientMessage`（扩展 `manifest.json` 里声明了自定义权限 `"superbrowser"`）**[已验证]**。
- 每个常驻进程是独立 Go 二进制（`env-kit` go1.21.4；`ziniao-gateway` go1.24.6，模块路径 `superbrowsernet/cmd/mixed`）**[已验证]**，用 `go version -m` 可完整还原依赖树。

### 2.3 多环境隔离粒度

| 层 | 路径 | 隔离方式 | 证据 |
|---|---|---|---|
| 内核 profile | `~/Library/Application Support/ziniaobrowser/instances/userdataN/` | **每环境独立 `--user-data-dir`**，含 `Preferences`、`Cache`、`Session Storage`、`GPUCache`、`Crashpad`、`blob_storage`、`DawnGraphiteCache` | 目录实测 **[已验证]** |
| 内核二进制 | `…/ziniaobrowser/env-kit/Core/` | 多版本内核共存，按环境指定 | 目录 + `--user-dir` 检测日志 **[已验证]** |
| 扩展数据 | 每环境 plugin profile（`getPluginId({ContainerId, BrowserType, Plugin})`） | 容器级隔离，`sharedCookieProfile` 可切换为共享 Cookie | 代码 **[已验证]** |
| 应用缓存 | `…/ziniaobrowser/app-cache/persist/__zb_assets_update_info_` | **机器密钥加密**（日志 `machineKeyPresent:true, machineKeyLength:32`） | 日志 **[已验证]** |
| 资产/扩展 | `assets-versions/<ver>/`、`assets/extensions/SBBackground.zip` | 版本化热更新，与 app 版本解耦 | 日志 + `ziniaoassets` **[已验证]** |

**关键结论**：隔离粒度是「进程 + 独立 user-data-dir」，不是同一浏览器实例内的 `session.fromPartition`。前者在 Cookie/IndexedDB/Service Worker/HTTP 缓存上天然彻底，代价是每环境一个完整内核进程（内存开销大，也意味着进程枚举即可发现"同时开了几个环境"）**[静态推断，路径与目录结构已验证]**。

### 2.4 账号体系与云端下发

- 登录态与业务数据在服务端；本地只缓存加密状态文件（`machineKey` 派生密钥 + AES，见 `profile aes encrypt failed`、`decrypt with %v` 字符串）**[已验证]**。
- **指纹配置由云端下发**：`EnvironmentData.Fingerprint = v.data`（服务端返回的 fingerprint blob），另有 `getKernelConfig(launchInfo, proxyCountry)` 按「内核版本 + 代理国家」取内核参数集 **[已验证]**（代码路径）。
- 启动时拉取 token 三元组并注入内核扩展上下文：`kernel_ext: { app_token, browser_token, user_id, user_token }`**[已验证]**。
- `resource_router.trusted_gateway_origins` 会被写入代理 `NoProxyList`（自家网关域名强制直连）**[已验证]**——这是一个可枚举的流量出口特征。

### 2.5 验证步骤

1. `plutil -p /Applications/ziniao.app/Contents/Info.plist` 取版本与 `ElectronAsarIntegrity`。
2. `bash scripts/asar-audit.sh` 一次性导出文件树、`package.json`、fuses、Go buildinfo。
3. 启动一个环境后执行 `ps -Ao pid,command | grep -i ziniaobrowser`，确认「一环境一进程」及实际命令行开关。
4. `ls ~/Library/Application\ Support/ziniaobrowser/instances/` 数环境目录，与 UI 中环境数对比。
5. 读 `logs/client/main.*.log`，检索 `user-data-dir detection`、`storage cipher`、`assets directory resolved` 三条锚点。

---

## 三、指纹隔离机制

### 3.1 维度清单（来自真实配置 schema）

以下字段直接取自主进程构造 `EnvironmentData.Detail.advanced` 的代码，**不是推测清单** **[已验证]**。`switcher` 语义：`1`=关闭/使用真实值，`2`=启用伪造。

| # | 维度 | 配置字段 | 关键子项 | 实现层 | 证据 |
|---|---|---|---|---|---|
| 1 | User-Agent | `ua` / `ua_version` | 完整 UA 串 | 内核 | 已验证 |
| 2 | UA-CH | `user_agent_data` | `brands[]`、`mobile`、`platform`、`architecture`、`bitness`、`model`、`platformVersion`、`uaFullVersion`、`wow64`、`sysPlatform` | 内核 | 已验证 |
| 3 | 时区 | `time_zone{switcher,value}` | IANA 名 | 内核 | 已验证 |
| 4 | 语言 | `language{switcher,value,lang,locales_chrome,locales_firefox}` | Chromium/Firefox 分别给 locale | 内核 | 已验证 |
| 5 | 分辨率 | `resolution{switcher,value:"W*H",screen_*,avail_*,phy_*,ratio}` | 物理/可用/DPR 全给 | 内核 | 已验证 |
| 6 | 字体 | `font{switcher,value,default_value}` | 自定义字体白名单 | 内核 | 已验证 |
| 7 | Canvas | `canvas{switcher}` | 噪声按环境+域名缓存 | 内核 | 已验证 |
| 8 | WebGL 图像 | `webgl_image{switcher}` | 渲染像素扰动 | 内核 | 已验证 |
| 9 | WebGL 元数据 | `webgl_metadata{switcher,provider,render}` | vendor/renderer 分开配 | 内核 | 已验证 |
| 10 | AudioContext | `audio_context{switcher}` | 指纹扰动 | 内核 | 已验证 |
| 11 | 媒体设备 | `media_device{switcher,audio_input,video_input,audio_output,communications,default}` | 设备枚举与 label | 内核 | 已验证 |
| 12 | ClientRects | `client_rects{switcher}` | 文本度量扰动 | 内核 | 已验证 |
| 13 | 语音合成 | `speech_voice{switcher,list[{name,lang,local_service,voice_uri,default}]}` | voices 列表整体伪造 | 内核 | 已验证 |
| 14 | CPU 核数 | `hardware_concurrency` | 整数 | 内核 | 已验证 |
| 15 | 内存 | `memery_device`（源码拼写） | deviceMemory | 内核 | 已验证 |
| 16 | DoNotTrack | `do_not_track` | — | 内核 | 已验证 |
| 17 | 蓝牙 | `bluetooth{switcher}` | — | 内核 | 已验证 |
| 18 | 电池 | `battery{switcher}` | Battery Status API | 内核 | 已验证 |
| 19 | **端口扫描防护** | `port_scan_protection{switcher,value}` | 把本地端口加入黑名单，阻断页面探测 127.0.0.1 | 内核 | 已验证 |
| 20 | 硬件加速 | `is_hardware_acceleration` | 影响 WebGL 走软/硬渲染 | 内核 | 已验证 |
| 21 | WebGPU | `web_gpu{switcher,value}` | 适配器信息 | 内核 | 已验证 |
| 22 | WebRTC | `web_rtc{switcher,local_ip,fake_ip}` | 私网 IP 隐藏/替换 | 内核 | 已验证 |
| 23 | 地理位置 | `geo_location{switcher,base_on_ip,lat,long,accuracy}` | 可按 IP 或手填 | 内核 | 已验证 |
| 24 | 平台/厂商 | `os`、`vendor`、`mixture_key` | 环境唯一键 | 内核 | 已验证 |

### 3.2 实现层判定：内核级，不是 JS 注入

三条独立证据：

1. **扩展侧无指纹 hook**。解包 `SBBackground.zip`（123 个文件、MV3、`content_scripts` 在 `document_start` 全帧注入）后检索 `getImageData`/`toDataURL`/`getParameter`/`hardwareConcurrency`：仅命中 OCR 上传路径（`_createImageData` 用于图片压缩）与 WebRTC **自检**（连 STUN 判断是否泄漏），**没有任何指纹伪造代码** **[已验证]**。
2. **配置以结构化数据交给内核**：`canvas:{switcher}`、`audio_context:{switcher}` 这类无具体值的开关，只有内核能消费；Firefox 侧直接映射为 `user.js` 偏好项（`media.peerconnection.ice.no_host`、`media.peerconnection.ice.default_address_only`、`network.proxy.socks_remote_dns`、`geo.provider.use_corelocation`、`intl.selected_languages`、`security.ssl3.*`）**[已验证]**。
3. **Canvas 噪声带持久化缓存**：`canvas_fingerprint_info`、`is_canvas_finger_printing_enable`、`fetch canvas fingerprint config`、`add canvas, cache exist`、`fp hash cache`（env-kit 字符串）。缓存键是「环境+域名」，说明设计目标是**同环境跨会话稳定、跨环境不同**——这正是平台侧一致性检测的主攻方向（见第八节）**[已验证字符串 + 静态推断语义]**。

> 仍存在一条 JS 通道：`EnvironmentData.JsScript`（每环境下发的脚本数组）。它是「用户自定义注入」还是内部注入有待实验确认 **[静态推断]**，验证方法见 9.7。

### 3.3 一致性验证：三组必测

| 测试 | 目的 | 判定 |
|---|---|---|
| 同环境 3 次重启 | 指纹是否稳定 | `canvas_hash`/`audio_hash`/`fonts` 全等 |
| 同环境内多次读取 | 噪声是否逐次抖动 | 3 次 `toDataURL` 全等 |
| 两环境对比 | 隔离是否真实 | 至少 Canvas/WebGL/Audio/字体 4 项不同 |

方法：把 `probe/fingerprint-probe.html` 分别在紫鸟环境与原生 Chrome 打开，点「保存为基线快照」→ 重启环境 → 「与基线快照比对」。差异项会以列表形式打印在页面顶部。

**原生 Chromium 基线（本机实测，用于对照）** **[已验证]**：

| 维度 | 基线值 |
|---|---|
| UA / UA-CH | `Chrome/157.0.0.0`；brands=`Not-A.Brand/99, Google Chrome/157, Chromium/157`，platform=`macOS` |
| platform / vendor | `MacIntel` / `Google Inc.` |
| hardwareConcurrency / deviceMemory | `10` / `16` |
| screen | `1470x956 @1x cd=30`，avail `1470x852` |
| timeZone / offset | `Asia/Shanghai` / `-480` |
| canvas 2D hash（3 次） | `6c586e93`，`stable=true`，`len=6510` |
| WebGL | vendor `Google Inc. (Apple)`，renderer `ANGLE (Apple, ANGLE Metal Renderer: Apple M5, Unspecified Version)`，`MAX_TEXTURE_SIZE=16384`，ext=39 |
| fonts（26 探测命中 14） | Arial, Helvetica, Times New Roman, Courier New, Verdana, Tahoma, PingFang SC, Hiragino Sans GB, Wingdings, Webdings, Georgia, Menlo, Monaco, Lucida Grande |
| clientRects | `261.98 × 16` |
| speechSynthesis.voices | `199` |
| 完整性 | `toDataURL`/`getContext`/`getParameter`/`RTCPeerConnection` 全部 `[native code]` |

> 注意基线里 `navigator.webdriver = true`：本机浏览器处于 CDP 自动化会话。这本身就是一个现成的对照——紫鸟**手动启动**的环境应为 `false`，用 SDK/RPA 启动时应为 `true`。

---

## 四、网络与代理机制

### 4.1 链路模型

```
内核进程 ── proxy=http://127.0.0.1:[proxy_listen_port] ──► ziniao-gateway ──► [PROXY_ENDPOINT]
             （无认证，仅本机）                             sing-box 出站        （认证在此层）
```

- 每环境一条入站：`EnvironmentData.InboundInfo = { ProxyType, Address, Port, Username, Password }`，端口来自服务端下发的 `proxy_listen_port` **[已验证]**。
- 之所以要本地桥：Chromium 的 `--proxy-server` **不支持 SOCKS5 用户名/口令**，本地无认证 HTTP 入站是行业通行解法；TLS 不被终结，因此浏览器 JA3 原样穿过（本次提供的 `scripts/proxy-bridge.js` 就是该模式的最小复现）**[已验证/静态推断]**。
- 代理来源枚举：`PLATFORM=1`（平台内置 IP）、`SELF=2`（自有）、`LOCAL=5`（本地/直连）**[已验证]**。

### 4.2 协议矩阵

`proxyProtocolTypes`：`direct, socks5, ssl, ssh, v2ray, vless, zless, multiss, cdnwss, rawtext, shadowsocks, http, https` **[已验证]**。

`ziniao-gateway` 的依赖树印证了实现：`sing-vmess`、`sing-shadowsocks`、`sing-box` option 结构（VLESS/Trojan/WireGuard/Hysteria 风格）、`github.com/cretz/bine`（Tor）、`github.com/gaukas/godicttls`（**ClientHello 可控**）、`github.com/fanyiguang/rawtext`（被 replace 到 `git.ziniao.com/d12-netlab/service/network/rawtext.git`，即私有 `rawtext` 协议）**[已验证]**。

> `godicttls` 的存在意味着网关自身可定制 TLS 指纹；但它只影响**网关到上游**这一段，浏览器到网关是明文 HTTP，所以**页面请求的 JA3 仍由内核决定**。

### 4.3 泄漏面清单

| 泄漏点 | 机制 | 验证方式 |
|---|---|---|
| DNS | Chromium 走 HTTP 代理 CONNECT → 域名交给代理解析；Firefox 由 `network.proxy.socks_remote_dns` 控制 | 用自建权威 DNS 记录查询来源；或 `dnsleaktest` 扩展 |
| WebRTC | `web_rtc{switcher,local_ip,fake_ip}`；Firefox 侧 `ice.no_host`、`default_address_only`、`nat_simulator.block_udp` | probe 的 `webrtc` 项：检查是否出现真实私网 IP、`srflx` 是否等于代理出口 IP |
| UDP/QUIC | `Raw.is_udp_proxy_enable`（版本 ≥ 某阈值才开，且受 `videoAuth` 影响）；否则 QUIC 回落 TCP | `chrome://net-export` 观察 QUIC 是否被禁用 |
| 直连白名单 | `NoProxyList += resource_router.trusted_gateway_origins` 的 host | 抓包看哪些域名绕过了代理 |
| 阻断页 | `stop.html` 跳转 `https://ziniao.block.j3e6di0o036cpreg88f2165z.com` | 触发黑名单访问，观察 DNS/SNI |
| 本地端口 | `port_scan_protection` 把 `proxy_listen_port` 等加入阻断表 | 页面内 `fetch('http://127.0.0.1:PORT')` 是否被拦截 |

### 4.4 验证步骤

1. 启动环境，`lsof -iTCP -sTCP:LISTEN -nP | grep -E 'ziniao|env-kit|gateway'` 找本地入站端口。
2. 页面内 `fetch('https://api.ipify.org?format=json')` 与宿主机直连结果对比，确认出口切换。
3. `python3 scripts/ja3_compare.py --proxy http://127.0.0.1:[PORT]`，与直连基线比对 `ja3_hash`/`akamai_hash`；若内核为 Chromium 5.124 而 UA 声称 126+，JA3 会落在旧版本特征上。
4. 抓包（`tcpdump -i any -n port [PROXY_ENDPOINT]`）确认：DNS 查询是否出现在本地出口（应为否），TLS SNI 是否为目标域名。
5. WebRTC：probe 的 `webrtc` 项应只出现 `srflx` 且 IP = 代理出口；出现 `host` 私网地址即泄漏。

---

## 五、反检测对抗分析

### 5.1 对抗点与暴露面

| 对抗点 | 紫鸟处理 | 可检测性 | 证据 |
|---|---|---|---|
| `navigator.webdriver` | 手动启动为 `false`；**SDK/RPA 模式置 `Raw.can_webdriver=true`** | 自动化场景直接暴露 | 代码 **[已验证]** |
| CDP 端口 | 内核可变现 `--remote-debugging-port=%d`，但需 `cdp_token`（`browserToken`） | 端口可扫，连上需 token；Electron 主进程自身拒绝 `--inspect`/`--remote-debugging-port` | env-kit 字符串 + 主进程代码 **[已验证]** |
| `chrome.superbrowser` | 私有扩展 API，页面若可达即为强特征 | `typeof chrome.superbrowser !== 'undefined'` | 扩展 manifest + contents.js **[已验证]** |
| 本地端口探测 | `port_scan_protection` 阻断 | 阻断行为本身可作为指纹 | 代码 **[已验证]** |
| 插件/PDF | Chromium 内核默认行为，未见特别处理 | `navigator.plugins.length` | **[静态推断]** |
| 行为模拟 | 未在客户端发现鼠标轨迹/键盘节奏模块（`SBBackground` 无相关代码） | 平台侧行为风控仍有效 | **[静态推断]** |
| 时间/时区一致性 | `time_zone` 与 `geo_location` 可分别配置，**存在配错风险** | `Date` 偏移 vs `Intl` vs IP 归属三方比对 | probe `locale` 组 |

### 5.2 跑分对比表（模板 + 基线）

| 检测项 | 原生 Chromium 基线 | 紫鸟环境 `[FINGERPRINT_ID]` | 判读 |
|---|---|---|---|
| creepjs trust score | 待测 | 待测 | <50 视为高风险 |
| pixelscan 一致性告警数 | 待测 | 待测 | 关注 "Timezone/IP mismatch" |
| browserleaks WebRTC | 无泄漏 | 待测 | 出现私网 IP = 泄漏 |
| `navigator.webdriver` | `true`（本次自动化会话） | 手动启动应 `false` | 自动化启动应为 `true` |
| Canvas 3 次稳定性 | `stable=true` | 待测 | `false` = 噪声逐次抖动 |
| WebGL1/2 renderer 一致 | 一致 | 待测 | 不一致 = 只 hook 单上下文 |
| 字体集合 vs UA 平台 | 一致（macOS 命中 PingFang） | 待测 | Windows UA + PingFang = 穿帮 |
| 函数完整性 | 全 native | 待测 | 非 native = JS 层注入 |
| JA3 vs UA 主版本 | 一致 | 待测 | 不一致 = 内核版本落后 |

> 跑分表必须由第九节流程实测填写；表中"待测"不是结论，是待采集项。

### 5.3 结论

- 紫鸟的对抗重心在**静态指纹**（维度覆盖度确实高，含 WebGPU/语音/媒体设备/端口扫描防护这类细项），**行为层与自动化痕迹层较弱**：没有发现轨迹合成、`isTrusted` 伪造、CDP 反检测模块 **[静态推断]**。
- `can_webdriver` 与 debug 端口是"按需开启"的设计，取舍明确：SDK 可用性优先于隐蔽性。

---

## 六、客户端逆向与安全分析

### 6.1 安装包结构

| 路径 | 大小 | 作用 |
|---|---|---|
| `Resources/app.asar` | 58,934,168 | 主进程 + preload + 渲染层入口 |
| `Resources/app.asar.unpacked/envkit/env-kit` | 15,052,290 | 内核/容器管理（Go 1.21.4） |
| `…/envkit/ziniao-gateway` | 34,184,242 | 代理网关（sing-box 派生，Go 1.24.6） |
| `…/envkit/z-tracking-client` | 15,038,640 | 埋点上报（buildinfo 已裁剪） |
| `app.asar:entries/main.vendor.jsc` | 41,448 | **bytenode V8 字节码**，非 JS |
| `…/assets/extensions/SBBackground.zip` | 8,407,550 | 内核扩展（MV3，ZipCrypto 加密） |
| `…/cdn/china-ips.txt` | 259,029 | 国内 IP 段（分流依据） |

### 6.2 反逆向措施与实测结论

| 措施 | 实测结果 |
|---|---|
| asar 完整性 | `Info.plist → ElectronAsarIntegrity` 存 SHA256；fuse `EnableEmbeddedAsarIntegrityValidation=enabled` → **改 asar 必须同步改 plist 并重签名** **[已验证]** |
| 只从 asar 加载 | `OnlyLoadAppFromAsar=enabled` → 放 `app/` 目录无效 **[已验证]** |
| Node 调试入口 | `RunAsNode` / `EnableNodeOptionsEnvironmentVariable` / `EnableNodeCliInspectArguments` 均 `disabled` **[已验证]** |
| 代码隐藏 | vendor 走 bytenode `.jsc`；`electron-runtime.json` 记录两份 sha256 **[已验证]** |
| 扩展载荷加密 | ZipCrypto（flags=0x9，method=8） **[已验证]** |
| 扩展口令 | **硬编码在主进程**：`{Path: getExtensionsPath("SBBackground.zip"), IsEssential:true, Key:"o@)%s5>~*b", ...}`；实测 `unzip -P 'o@)%s5>~*b'` 成功解出全部 123 个文件 **[已验证]** |
| 本地状态加密 | 机器密钥（32B）+ AES；`profile aes encrypt failed` **[已验证/静态推断]** |

> 结论：asar 层防护是"防篡改"而非"防阅读"——`asar` 本身无加密，任何本地用户都能读；真正的门槛只有 bytenode 的 `.jsc` 与扩展口令，而后者的口令就在明文 bundle 里。

### 6.3 动态分析要点

1. **进程与命令行**：`ps -Ao pid,command | grep -E 'ziniaobrowser|env-kit|gateway'`，重点看 `--user-data-dir`、`--remote-debugging-port`、`--proxy-server`（注意：代理可能通过 `session.setProxy` 而非命令行，故 `proxy-server` 在 bundle 中为 0 命中）**[已验证]**。
2. **调试端口**：`lsof -iTCP -sTCP:LISTEN -nP | grep -E '127.0.0.1'`；命中后 `curl http://127.0.0.1:PORT/json/version`——带 token 校验时会 401/403，这本身就是"端口存在但受保护"的证据。
3. **注入点定位**：在页面上下文比对 `Function.prototype.toString`（probe 的 `integrity` 组）；若全 native，则伪造在内核，需转内核二进制比对（`strings` 搜 `canvas_fingerprint_info`）。
4. **扩展行为**：`chrome://extensions` 看 `SBBackground` 的 content scripts 注入范围；`js/inject_script.js` 是 MAIN world 注入入口，需单独审计（本次未展开）**[静态推断]**。

### 6.4 PoC：指纹 hook 注入（JS 注入派对照样本）

完整实现见 `poc/hook-inject.js`（确定性噪声 + `toString` 伪装 + WebGL/Audio/navigator 覆盖），核心片段：

```js
function hash32(x, y, seed) {
  let h = (x * 374761393 + y * 668265263 + seed * 2246822519) | 0;
  h = (h ^ (h >>> 13)) * 1274126177 | 0;
  return (h ^ (h >>> 16)) >>> 0;
}
function perturb(data, w, strength) {
  const n = strength | 0;
  for (let i = 0; i < data.length; i += 4) {
    const px = (i >> 2) % w, py = (i >> 2) / w | 0, r = hash32(px, py, SEED);
    data[i]     = (data[i]     & ~n) | (r & n);
    data[i + 1] = (data[i + 1] & ~n) | ((r >>> 8) & n);
    data[i + 2] = (data[i + 2] & ~n) | ((r >>> 16) & n);
  }
}
// toDataURL 与 getImageData 必须同源，否则 probe 的 C3 项直接命中
C.toDataURL = markNative(function toDataURL() {
  try { return origToDataURL.apply(noisyCanvas(this), arguments); }
  catch (e) { return origToDataURL.apply(this, arguments); }
}, 'toDataURL');
```

注入：`Page.addScriptToEvaluateOnNewDocument({ source: <文件全文> })`，或扩展 `content_scripts` + `world: "MAIN"`。

### 6.5 PoC：检测器（与上面的 hook 对照）

完整实现见 `poc/detect-hook.js`，判定逻辑是**证据交叉**而非单一 flag：

```js
// 1) toString 自身是否被改写
const tsSrc = Function.prototype.toString.call(Function.prototype.toString);
if (!/\[native code\]\s*\}\s*$/.test(tsSrc)) flag('T1', 'toString 被伪装');

// 2) 参数个数（真 Chrome：toDataURL.length===0，getImageData.length===4）
if (HTMLCanvasElement.prototype.toDataURL.length !== 0) flag('T2b', '包装后伪装 native');

// 3) 噪声确定性：3 个全新上下文必须完全一致
const a = draw().toDataURL(), b = draw().toDataURL(), c = draw().toDataURL();
if (!(a === b && b === c)) flag('C1', '噪声逐次抖动');

// 4) WebGL1 与 WebGL2 的 renderer 必须一致（只 hook 一者会穿帮）
if (gl2Renderer !== gl1Renderer) flag('G6', '只 hook 了单个上下文');
```

---

## 七、同类产品技术对比

| 维度 | 紫鸟 6.50.2 | AdsPower | 比特浏览器 | Multilogin |
|---|---|---|---|---|
| 外壳 | Electron 30.5.1 | Electron | Electron | 自研客户端 |
| 内核 | 定制 Chromium 5.124/5.126 + 定制 Firefox 6.148 | SunBrowser/FlowerBrowser（Chromium 定制） | Chromium 定制内核 | Mimic（Chromium fork）+ Stealthfox（Firefox fork） |
| 指纹实现层 | 内核级（配置下发 → 内核 `Raw`/prefs） | 内核级 **[公开资料]** | 内核级 **[公开资料]** | 内核级（源码 patch）**[公开资料]** |
| 指纹维度覆盖 | ≥24 项，含 WebGPU/语音/媒体设备/**端口扫描防护** | 20+ 项 **[公开资料]** | 20+ 项 **[公开资料]** | 25+ 项，含字体/媒体 **[公开资料]** |
| 隔离粒度 | 每环境独立 `user-data-dir` + 独立进程 | 每环境独立 profile **[公开资料]** | 每环境独立 profile **[公开资料]** | 每 profile 独立容器 **[公开资料]** |
| 代理协议 | 13 种（含 vless/v2ray/rawtext/cdnwss/ssh）+ 本地入站桥 | HTTP/SOCKS5/SSH，本地 API 绑代理 **[公开资料]** | HTTP/SOCKS5/SSH **[公开资料]** | HTTP/SOCKS5，支持自有 IP **[公开资料]** |
| 自动化接口 | `--remote-debugging-port` + `cdp_token`，SDK/RPA 模式 | Local API（`local.adspower.net:50325`）+ Selenium/Puppeteer **[公开资料]** | 本地 API + Selenium **[公开资料]** | 本地 API + Selenium/Puppeteer **[公开资料]** |
| 云端下发 | 指纹 blob + 内核配置按「版本+国家」 | 有 **[公开资料]** | 有 **[公开资料]** | 有 **[公开资料]** |
| 反逆向 | asar 完整性 + bytenode + 扩展加密（口令硬编码） | 未见公开分析 **[公开资料]** | 未见公开分析 **[公开资料]** | 客户端加固较强 **[公开资料]** |

> 该表除紫鸟列外均为公开资料，**同行版本迭代快，字段含义可能变化**，落地前需在同版本上复测。

---

## 八、风险与局限

### 8.1 技术可检测性（按检出难度排序）

| # | 检测点 | 原理 | 难度 |
|---|---|---|---|
| 1 | **时区 vs IP vs 语言三方不一致** | 指纹可配、代理国家可配，两者独立 → 组合错误率最高 | 极低（平台必查） |
| 2 | **JA3/JA4 vs UA 主版本** | 内核 5.124 ≈ Chromium 124，若 UA 配到 131+ 则 TLS 特征落后 | 低 |
| 3 | **UA-CH 与 UA 不一致** | `brands`/`platformVersion` 是独立字段，容易漏改 | 低 |
| 4 | **字体集合 vs 平台** | Windows UA 却命中 PingFang SC/Helvetica | 低 |
| 5 | **Canvas 噪声非确定性** | 若按读取次数抖动，两次 `getImageData` 即暴露 | 中（取决于缓存实现） |
| 6 | **WebGL 能力矩阵不自治** | renderer 写 Apple M1，`MAX_TEXTURE_SIZE` 却是 4096 | 中 |
| 7 | **CDP/自动化痕迹** | `can_webdriver`、debug 端口、`chrome.superbrowser` | 中 |
| 8 | **行为特征** | 无轨迹合成 → 点击直线、零抖动、`isTrusted` 与输入管线不符 | 高（平台侧模型） |

### 8.2 稳定性与版本风险

- **内核热更新**：内核 zip 独立下载，`assets-versions/<ver>` 与 app 版本解耦。升级后同一环境的 canvas/webgl 噪声基线可能变化 → 老账号"指纹跳变"，这是运营侧最实际的封号诱因 **[静态推断，机制已验证]**。
- **双内核差异**：Chromium 与 Firefox 的维度覆盖不同（`webgl_metadata` 走 `webgl_vendor` vs `firefox_data.webgl_vendor`），同一环境切内核会造成指纹整体漂移 **[已验证]**。
- **profile 体积**：独立 user-data-dir 意味着每环境一份缓存，几十环境时磁盘与启动耗时线性增长；`BatchClearBrowserUserData`/`clean browser cache` 是其内置缓解手段 **[已验证]**。
- **本地单点**：`env-kit` 是 Go 单进程，崩溃时 `recover` 系列字符串（`recover close browser`、`recover terminate browser process`）说明作者已预见；但 SDK 场景下进程被 kill 会留下 `custom-lockfile` 残留 **[已验证]**。

### 8.3 本地安全面

- 扩展口令硬编码 → 任何人可解包审计（也可被恶意软件替换为投毒扩展，因为 `IsEssential:true` 的加载路径可被劫持）。
- debug 端口默认关闭，但 SDK 模式会开；若 `cdp_token` 校验实现有缺陷，等于本机任意进程可接管浏览器。
- 机器密钥 32B 加密本地状态，但密钥本身由 `node-machine-id` 派生 → 同机可解，防的是"拷走文件"而非"同机读取" **[静态推断]**。

---

## 九、实验方案汇总（可复现操作清单）

> 全部在快照虚拟机内执行；`[CLIENT_VERSION]`、`[INSTALL_PATH]`、`[PROXY_ENDPOINT]`、`[FINGERPRINT_ID]` 按实际替换。

1. **建基线**：干净快照 → 安装原生 Chrome `[CHROME_VERSION]` → 打开 `probe/fingerprint-probe.html` → 「保存为基线快照」。
2. **装客户端**：`[INSTALL_PATH]` 安装紫鸟 `[CLIENT_VERSION]`，不登录，先做静态审计。
3. **静态审计**：`APP=[INSTALL_PATH] bash scripts/asar-audit.sh`，产物落 `evidence/`：文件树、`package.json`、fuses、Go buildinfo、扩展加密标志。
4. **记录 fuses**：确认 `EnableEmbeddedAsarIntegrityValidation`/`OnlyLoadAppFromAsar` 开启，`RunAsNode`/`CliInspectArgs` 关闭。
5. **环境创建**：建两个环境 `ENV_A`/`ENV_B`，指纹参数除 `[FINGERPRINT_ID]` 外尽量一致，便于隔离对比。
6. **同环境稳定性**：在 `ENV_A` 跑 probe → 保存快照 → 完全退出客户端 → 重启 `ENV_A` → 比对；记录差异项。
7. **跨环境隔离**：`ENV_B` 跑 probe，与 `ENV_A` 比对 Canvas/WebGL/Audio/字体四项，应全部不同。
8. **注入层判定**：probe 的 `automation.integrity` 全为 `native` → 内核级；出现 `HOOKED` → JS 层，转 9.9 抓注入脚本。
9. **抓注入脚本**：若为 JS 层，用 CDP `Debugger.enable` + `Debugger.scriptParsed` 全量导脚本，检索 `getImageData`/`getParameter`。
10. **代理链路**：`lsof -iTCP -sTCP:LISTEN -nP | grep -E 'gateway|env-kit'` 找本地入站；`node scripts/proxy-bridge.js --listen 127.0.0.1:18080 --socks [PROXY_ENDPOINT]:1080 --user [PROXY_USER] --pass [PROXY_PASS]` 复现桥接。
11. **出口校验**：环境内访问 `https://api.ipify.org?format=json`，与 `[PROXY_ENDPOINT]` 归属地对比，确认无回落直连。
12. **DNS 泄漏**：自建权威 NS 记录查询源 IP（或 `dnsleaktest`），确认解析发生在代理侧；同时 `tcpdump -i any port 53` 看本地是否有查询。
13. **WebRTC 泄漏**：probe 的 `webrtc` 项；期望只有 `srflx` 且 IP=出口，`host` 私网地址出现即泄漏。
14. **JA3/JA4**：`python3 scripts/ja3_compare.py --proxy http://127.0.0.1:[PORT]`，比对 `ja3_hash`/`akamai_hash` 与 UA 宣称版本。
15. **端口扫描防护**：页面内 `fetch('http://127.0.0.1:[proxy_listen_port]')`，观察是否被阻断（阻断=防护生效，同时也是特征）。
16. **自动化模式**：用 SDK/RPA 启动 `ENV_A`，probe 读 `navigator.webdriver`，并 `lsof` 确认 debug 端口；`curl http://127.0.0.1:[PORT]/json/version` 验证 token 校验。
17. **跑分对照**：creepjs / pixelscan / browserleaks 三站在两环境各跑 3 次，填 5.2 表。
18. **行为检测**：录制 60 秒真实操作与脚本操作，比较鼠标轨迹曲率、按键 dwell/flight、滚动惯性，评估行为层可检测性。
19. **内核升级对照**：升级内核版本（或改 `packageKernel` 指向新 zip）后重跑 6/7/14，记录指纹跳变项。
20. **归档**：`evidence/` + probe JSON + 抓包 pcap + 跑分截图，按环境 ID 命名。

---

## 十、附录

### 10.1 交付物清单

| 文件 | 说明 |
|---|---|
| `probe/fingerprint-probe.html` | 指纹检测页：24 组维度 + 稳定性/一致性判定 + 快照比对 + JSON 导出 |
| `poc/hook-inject.js` | 指纹 hook PoC：确定性噪声、WebGL/Audio/navigator 覆盖、toString 伪装、自检 |
| `poc/detect-hook.js` | 检测器：toString/参数个数/噪声确定性/跨上下文/字体-UA/自动化痕迹，输出 0–100 风险分 |
| `scripts/asar-audit.sh` | 静态审计一键脚本（asar 树、package.json、fuses、Go buildinfo、扩展加密标志） |
| `scripts/proxy-bridge.js` | 本地 HTTP → 上游 SOCKS5（带认证）桥，复现"每环境独立出口"链路 |
| `scripts/ja3_compare.py` | JA3/JA4/Akamai 指纹对照（直连 vs 经代理） |

### 10.2 抓包字段说明

| 字段 | 期望值 | 异常含义 |
|---|---|---|
| `CONNECT` 目标 | `host:443`（域名而非 IP） | 出现 IP → 应用层已解析，DNS 可能本地泄漏 |
| TLS `ClientHello` SNI | 目标域名 | SNI 与 Host 不一致 = 中转/伪装 |
| `ja3_hash` | 与 UA 主版本匹配的内核特征 | 落后一个大版本以上 = 内核未更新 |
| DNS 查询源 | 代理侧 IP | 出现本机/本地 ISP IP = DNS 泄漏 |
| STUN `Binding Request` | 经代理发出 | 直连发出 = WebRTC 泄漏 |
| HTTP/2 `SETTINGS` | 与内核版本一致 | 与 UA 不符 = HTTP 层被中间件改写 |

### 10.3 复现命令速查

```bash
# 静态审计
APP=/Applications/ziniao.app bash scripts/asar-audit.sh

# 扩展解包（口令来自主进程 bundle 的 Key 字段）
unzip -P 'o@)%s5>~*b' \
  /Applications/ziniao.app/Contents/Resources/app.asar.unpacked/assets/extensions/SBBackground.zip \
  -d /tmp/sbext

# 内核/守护进程构建信息
go version -m /Applications/ziniao.app/Contents/Resources/app.asar.unpacked/envkit/ziniao-gateway

# 本地入站端口
lsof -iTCP -sTCP:LISTEN -nP | grep -iE 'ziniao|gateway|env-kit'

# 代理桥 + 出口校验
node scripts/proxy-bridge.js --listen 127.0.0.1:18080 --socks [PROXY_ENDPOINT]:1080 --user [PROXY_USER] --pass [PROXY_PASS]
curl -x http://127.0.0.1:18080 https://api.ipify.org?format=json

# TLS 指纹对照
python3 scripts/ja3_compare.py --proxy http://127.0.0.1:18080 --impersonate chrome124
```

### 10.4 证据索引

| 结论 | 证据文件/命令 |
|---|---|
| Electron 30.5.1 / 版本号 | `Info.plist`、`Electron Framework/Resources/Info.plist` |
| 双内核矩阵 | `app.asar:package.json → packageKernel` |
| fuses 状态 | `MacOS/ziniao` 与 `Electron Framework` 的 fuse wire |
| 24 项指纹 schema | `entries/main.index.js`（`EnvironmentData.Detail.advanced`） |
| 代理 13 协议 | `entries/main.index.js`（`proxyProtocolTypes`） |
| 扩展口令 | `entries/main.index.js`（`BuiltinPluginConfig.OtherPlugin.push`） |
| 内核级实现判定 | `SBBackground.zip` 解包后 grep 结果 + env-kit 字符串 |
| 每环境 user-data-dir | `~/Library/Application Support/ziniaobrowser/instances/userdata1/` |
| 机器密钥加密 | `logs/client/main.*.log`（`storage cipher initialized`） |
| CDP 暴露条件 | `main.index.js`（`can_webdriver` + `remote-debugging-port`） |
| 原生基线数值 | 本机 probe 核心实测输出（见 3.3 表） |
