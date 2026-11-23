# 加固与接入验证记录（2026-11-22 · 6.50.2-latest.7 · macOS arm64）

> 全部结论来自本机实测；`[待实测]` 表示需要登录店铺/真实环境才能验证。
> 涉及生产账号的操作（启动店铺浏览器）**未执行**：当前账号店铺数为 0，且不应在未授权情况下启动真实环境。

---

## 1. CLI 真实面（推翻既有指南中的一处命令）

| 观测 | 结果 | 含义 |
|---|---|---|
| `ziniao --help` | `browser / auth / fix / start / shutdown` 五组 | 编排面就是这 5 组 |
| `ziniao browser start -h` | `--id --name --url --mode normal\|agent --headless --privacy --json` | **没有** `--remote-debug-port` |
| `ziniao browser start --id 1 --remote-debug-port 19999` | `Unknown argument for browser start: --remote-debug-port` | 该参数在本版本被拒绝 |
| `ziniao browser start --id 1 --mode agent --json` | 流式 JSONL：`progress(resolving/preparing/launching)` → `{ok:false,error:"Ziniao user is not logged in"}` | **先按行解析**，不要整体 `json.loads` |
| 同上，退出码 | `0`（失败也是 0） | **不能靠 exit code 判成败**，只看 `ok` |
| `ziniao browser list --json`（已登录后） | `{"ok":true,"data":{"page":1,"limit":100,"total":0,"items":[]}}` | 账号店铺数 = 0；列表在 `data.items` |
| `ziniao auth machinecode --json` | `{"ok":true,"data":{"machineCode":"72F1D6CB-6B11-535E-AE9D-B91A52F4"}}` | 与 `env-kit/.identify` 一致 |
| `ziniao fix startup -h` | 仅 `startup` 一个 action | 修复入口单一 |
| daemon 停止后 `browser list` | `{"ok":false,"error":"Ziniao user is not logged in"}` | **误导性错误**：daemon 未启动也报"未登录"；DS-Bot 应先查 `/health` 或先 `ziniao start` |
| `ziniao start ws-control --port N [--key] [--host] [--allowed-origin]` | 生效，日志 `WS control started on port N` | GUI 控制通道 |

**CDP 端口从哪来**：CLI 内部命令是 `{command:"browser.start", args:{storeId,storeName}}`，响应 `data` 含 `{storeId, debugPort, downloadFolderPath, zclawLaunchHint}`（主进程 bundle，`[已验证-代码]`）。因此**端口在启动响应里**，不需要 ps 扫描；ps 扫描只作为兜底。

---

## 2. `can_webdriver` 补偿：三个硬结论

测试对象：本机 Chromium 157（Agent 浏览器，`navigator.webdriver=true`），载荷 `hardening/inject-webdriver.js`，驱动器 `hardening/cdp-compensate.js`。

| 场景 | 主 Realm | iframe Realm | 判定 |
|---|---|---|---|
| 基线（未补偿） | `true` | `true` | 一致暴露 |
| 仅主 Realm 打补丁（页面内 eval） | `false` | `true` | 跨 Realm 一比即破 |
| CDP `addScriptToEvaluateOnNewDocument` + **同会话** | `false` | `false` | COVERED |
| 注入会话关闭后再建 iframe | `false` | `true` | **静默退化 → LEAK** |

结论：
1. **补丁是 Realm 级的**，iframe 是独立 Realm；不做全 frame 覆盖等于没补。
2. **CDP 注入是会话级的**：注入器必须与驱动器同寿命；断线重连后必须重装，否则出现"旧文档已改、新 frame 未改"的半补丁状态（比不补更异常）。
3. **必须 `Page.enable` + 真实导航**：首次用 `Page.reload` 注入未生效（`__WD_PATCHED__=false`），改为 `Page.enable` + 带 cache-bust 的 `Page.navigate` 后才覆盖成功。紫鸟内核是否同样需要 `[待实测]`。
4. 伪装质量：补丁后 `Function.prototype.toString.call(Function.prototype.toString)` 仍为 `[native code]`，`toString.name/length=toString/0`，descriptor `{get:function,set:undefined,configurable:true,enumerable:true}` 与原版一致 —— 静态检查（T1/T1b/T2b）打不出来，**只能靠跨 Realm 或行为/时序**。
5. Worker 侧：本机 Chrome 中 `WorkerNavigator.webdriver` 为 `undefined`（未暴露），因此 Worker 交叉校验在此版本上不可用；不作为判据。

---

## 3. 门禁与基线工具（均已跑通）

| 工具 | 实测 |
|---|---|
| `preflight.js` | 11 项：UA-CH 主版本/平台、TZ 自洽、字体 vs 平台、语言、Canvas 稳定性、函数完整性、`webdriver`、plugins、私有 API、出口 IP；`FAIL>0 → exit 1` |
| 基线（未补偿） | `UA-CH.major PASS(UA=157 CH=157)`、`FONT.platform PASS(PingFang/Hiragino/Menlo)`、`CANVAS.stable PASS(hash=6c586e93)`、`INTEGRITY PASS`、`WEBDRIVER WARN(true)` → `ALLOW` |
| 补偿后 `--strict` | `WEBDRIVER PASS(false)`，其余不变 → `ALLOW` |
| 注意 | `about:blank` 上 `navigator.userAgentData` 为 `undefined`（非 secure context），**UA-CH 必须在 https 页面校验**，否则误报 |
| `baseline.sh` | `snapshot` 产 6 个文件（app/core/assets/instances/fingerprint）；两次快照 `diff` 无差异、`fingerprint.json` 逐字段一致 → 检测是确定性的 |

> `app.asar` 文件 sha256（`e9aad09f…`）与 `Info.plist` 的 `ElectronAsarIntegrity`（`d639c2b7…`）口径不同，不可直接比对。

---

## 4. 自动化通道实测（本次新增，最关键）

### 4.1 zclaw HTTP 服务（9481）

```bash
curl -s http://127.0.0.1:9481/health
# {"ok":true,"service":"ziniao-zclaw","port":9481,"loggedIn":true,
#  "status":{"enabled":false,"workspaceName":"Ziniao Browser","hasApiKey":true,
#            "boundAccounts":0,"runningStores":0,
#            "localUser":{"id":17952912863852,"username":"boss","companyId":17952912863262,
#                         "companyName":"尾号2304的公司101"},
#            "baseUrl":"http://127.0.0.1:9481",
#            "toolsInvokeUrl":"http://127.0.0.1:9481/zclaw/tools/invoke",
#            "websocketUrl":"ws://127.0.0.1:9481/zclaw/ws","latestLog":null}}
```

| 端点 | 鉴权 | 实测 |
|---|---|---|
| `GET /health` | 无 | 200，返回 `loggedIn / hasApiKey / runningStores / localUser` —— **天然的 readiness gate** |
| `POST /zclaw/tools/invoke` | 登录 + `x-zclaw-api-key` | 未登录：`401 {"ret":-1,"msg":"Ziniao user is not logged in"}`；已登录无 key：`401` 通用文案 |
| 同上，带假 key | — | `401 ACCOUNT_API_KEY_BIND_CONFIRMATION_FAILED`「API Key 绑定确认失败」→ **尝试绑定**并写盘 |
| `ws://127.0.0.1:9481/zclaw/ws` | access token | 握手通过后服务端回 `{"type":"error","msg":"Invalid access token"}` |
| `9480` | — | 所有路径 `403 {"ret":-1,"msg":"Forbidden"}` |
| `16812`（进程动态端口） | — | `{"err":"请使用POST方法"}`（404）→ **仅 POST 的本地 API**，用途 `[待实测]` |

**副作用（需记录）**：带假 key 的请求把 `app-cache/persist/__zb_zclaw_settings` 写脏（mtime 与请求同刻，`hasApiKey` 由 false 变 true）。已隔离为 `__zb_zclaw_settings.probe-contaminated.bak`，进程已全部退出。→ 结论：**不要用假 key 探测 9481**；一旦污染，删该文件并重启客户端恢复 `[待实测]`。

### 4.2 GUI WS 控制通道（`start ws-control --port N`）

| 探测 | 结果 |
|---|---|
| `curl http://127.0.0.1:19999/` | `426 Upgrade Required`（仅 WS） |
| WS 握手（无 key） | 成功 `open`，随即 `1008 policy violation / "decrypt failed"`，无消息 |
| WS 握手（`?key=test`） | 同上 `decrypt failed` |
| 结论 | 协议是**加密帧**，明文探测拿不到 schema；`--key` 参与解密。**不值得逆向**，CLI 子命令已覆盖同等能力 |

### 4.3 内核下载源（补齐此前 `[待实测]`）

主进程配置串：`sdkCoreDownload: https://browser.s3.cn-north-1.amazonaws.com.cn`、`sdkSecureDns: https://dns64.dns.google/dns-query`、`aiAgent: https://agent-swarm.ziniao.com/api/v1/`。→ 版本锁定/离线部署可按该 bucket 抓包确认 `[待实测：具体对象路径]`。

---

## 5. 当前机器配置体检

| 项 | 值 | 结论 |
|---|---|---|
| App | 6.50.2-latest.7 / arm64 | 与报告一致 |
| 登录态 | 已登录，`username=boss`，`companyName=尾号2304的公司101` | 会话可恢复（启动后数秒内完成） |
| 店铺数 | **0**（`total:0`） | 无法做"启动店铺 → 拿 debugPort"的端到端验证 `[待实测]` |
| 内核 | `env-kit/Core/` 为空 | 从未下载；登录后首启仍需下载 |
| zclaw | `enabled:false`，`boundAccounts:0`，`hasApiKey:true` | 未开通生态 API，_invoke_ 不可用 |
| 运行中内核 | 无 | 当前无 CDP 端点 |
| 清理状态 | 进程 0 残留；被污染设置已隔离 | 机器已恢复 |

---

## 6. 对接结论（DS-Bot）

| 层 | 状态 | 走法 |
|---|---|---|
| 编排（启停/列表） | ✅ 可用 | `ziniao browser list/start/close --json`；解析 `ok`、`data.items`、`data.debugPort` |
| 就绪探测 | ✅ 可用 | `GET 127.0.0.1:9481/health` → `loggedIn / runningStores` |
| 页面（CDP） | ⚠️ 未验证 | 端口应在 `browser.start` 响应的 `debugPort`；本机无店铺，无法验证 `[待实测]` |
| 官方生态 API | ⚠️ 需开通 | `POST /zclaw/tools/invoke` + `x-zclaw-api-key`，需 `enabled:true` 且 boundAccounts>0 |
| GUI 控制 WS | ⚠️ 加密 | 需 `--key`，协议不透明，不建议 |
| 隐身 | ❌ 必然暴露 | `can_webdriver=true`；补偿须 **全 frame + 同会话**，并用 `cdp-compensate --selftest` 门禁 |

**最小可行链路（待有店铺后一次跑通）**：
`ziniao browser start --id X --mode agent --json` → 取 `data.debugPort` → `preflight --strict` → 同会话 `cdp-compensate --install --reload --selftest`（要求 COVERED）→ 任务 → `browser close` → `baseline snapshot`。

---

## 7. 本次操作留痕

- 启动过 GUI / ws-control，均已终止；`ps` 确认 0 残留。
- 未启动任何店铺环境（无店铺，且不应在未授权下启动）。
- 未修改客户端二进制、未改 asar、未写登录凭据。
- 唯一副作用：`__zb_zclaw_settings` 被假 key 探测写脏，已隔离备份（`.probe-contaminated.bak`）。

---

## 8. 本轮闭环（自建农场路线）

| 项 | 结果 |
|---|---|
| 出口链路离线验证 | `farm/verify-egress.js` **8/8 PASS**（0.7 s）：代理看到域名、页面带代理标记头、`egress.test` 本地不可解析仍可达 ⇒ DNS 在代理侧 |
| 框架注入痕迹 | `farm/driver.js scan` → **CLEAN**：`webdriver=false`、`automationKeys=[]`、`toString` 原生 |
| 驱动能力 | `goto/eval/click/type[--keys]/shot` 全部实跑通过（`--keys` 产生 3 次 keydown，input 值 `abc`） |

过程中修掉两个自身 bug：

1. **CDP 定时器未清理**：每个请求挂 15 s `setTimeout` 不 `clearTimeout`，导致 `farm.js check` 15 s、`preflight.js` 18 s 才退出；修后 71 ms / 3.3 s。
2. **代理转发用 `net.connect` 直通**：把上游 status line/headers 塞进了 `ServerResponse`，页面显示原始报文；改用 `http.request` 后正常。

已知遗留（不影响闭环）：
- 本机无外网，真实出口 IP/DNS 归属仍需 `POST /instances/:a/check?ip=1` 在有网环境补一次。
- `--headless=new` 的 UA 带 `HeadlessChrome`；生产用 headful。
