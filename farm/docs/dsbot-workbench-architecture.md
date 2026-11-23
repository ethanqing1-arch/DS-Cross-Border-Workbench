# DS-Bot 工作台 · 浏览器引擎接入与对外服务架构（v1.3）

> 状态：**已修订**。v1.0 的评审问题与修订依据见同目录 [`dsbot-workbench-review.md`](./dsbot-workbench-review.md)。
> 基线：`ziniao-report/farm/` 现有实现（`farm.js` / `control.js` / `ledger.js` / `driver.js` / `docker/`）。
> 本轮新增：`gateway/server.js`、`scripts/mock-ip-echo.js`、`scripts/verify-dual-env.sh`。

## 变更记录

| 版本 | 变更 |
|---|---|
| **v1.3** | ① profile 改按平台分区 `profiles/<platform>/<account>`（未声明平台落 `_unsorted/`），control 与 `GET /v1/sessions` 支持 `?platform=`；② 版本契约落 `contract.js` + `package.json` version `1.1.0` + `GET /v1/version`（可带 `?require=`），网关能力表改从契约取；③ camoufox 升为一等引擎：网关侧 worker 传输适配，`/v1/tasks` 跑 `goto/eval/shot/scan`，`engines.camoufox` 由探针判定，`degraded` 取值退役 |
| **v1.2** | ① camoufox 任务通道落地（goto/eval/shot/scan）；② 网关 `--controls` 跨宿主聚合去重；③ 补 macOS 4 容器实测数据 |
| **v1.1** | ① 修正容量表与公式不一致；② `POST /tasks` 幂等 TTL 落到实现；③ 补 `GET` 删除后语义（200 + `status=stopped`）；④ 限流改为"参考实现单桶"并标注分桶为阶段 2；⑤ camoufox 任务通道标为**未实现**（网关返回 422）；⑥ 全局 `dup` 标为**待实现**并给临时替代；⑦ `tenant` 统一走 `X-Tenant-Id`；⑧ 新增 `FARM_IP_ECHO` 闭合出口 IP 校验；⑨ 补 `attach --seed` 语义；⑩ 补 macOS 容器缺 `TZ` 会 `check` 失败的坑；⑪ 补 linux150 的 GPU 前提（swiftshader + 伪造参数） |
| v1.0 | 初版：四引擎接入、九接口契约、扩展点、部署与验收 |

---

## 一、总体架构

```
DS-Bot 工作台
   │ HTTPS + Bearer TOKEN + X-Tenant-Id
   ▼
EDGE_GW（TLS/鉴权/限流）              ← 可复用现有网关
   │
   ▼
dsbot-gateway  ×N（无状态）           ← 新增：gateway/server.js
   │  ├─ 会话生命周期 → farm control  → farm.js start/attach/stop
   │  ├─ 任务执行     → driver.js
   │  └─ 去重         → farm.js dup
   ▼
farm-control@H1/H2/H3（127.0.0.1:19555，x-farm-token）
   │
   ├─ chromium 148（macOS 原生，CDP）
   ├─ linux150（Docker+Rosetta，CDP，含 GPU 元数据）
   ├─ chrome 157（宿主真实，CDP）
   └─ camoufox 158（Firefox worker，Playwright，仅有头）
   │
   ▼
ledger（每机 SQLite：accounts / checks）
```

| 组件 | 状态 | 职责 | 落地位置 |
|---|---|---|---|
| `farm.js` | 现有 | `start`/`attach`/`stop`/`list`/`check`/`dup` | `farm.js` |
| `control.js` | 现有（本轮补 `attach`、`fp_seed`/`chrome` 透传、`cdp` 字段） | 单机控制面 | `control.js` |
| `ledger.js` | 现有（本轮补 `cdp` 列） | 台账 | `ledger.js` |
| `driver.js` | 现有 | `scan`/`goto`/`eval`/`click`/`type`/`shot` | `driver.js` |
| `docker/` | 现有 | linux150 运行镜像（Xvfb + socat） | `docker/` |
| `camoufox_worker.py` | 现有（本轮加任务通道） | Firefox 深人设；`--task` 支持 `goto/eval/shot/scan` | `camoufox_worker.py` |
| `dsbot-gateway` | **新增** | 多租户编排、幂等、任务分发、聚合校验 | `gateway/server.js` |
| `mock-ip-echo` | **新增** | 本地出口 IP 回显，闭合 IP 校验 | `scripts/mock-ip-echo.js` |
| `verify-dual-env.sh` | **新增** | 双环境验收脚本 | `scripts/verify-dual-env.sh` |

---

## 二、引擎接入

### 2.1 两种模式

| 模式 | 做法 | 适用 | 代价 |
|---|---|---|---|
| A. CDP 直连 + `attach` | 外部起引擎 → `POST /instances/attach` 登记 | 内部调试、单机小批量 | 需自管进程与端口 |
| B. gateway 统一入口（推荐） | DS-Bot 只调 `/v1/*` | 多租户对外 | 多一跳 ~2–5 ms |

两者共用同一份 ledger 与 `check`/`dup`，不产生第二套实现。

### 2.2 四引擎参数与能力边界

| engine | 形态 | 协议 | 接入 | 必填 | 能力边界（**不得抹平**） |
|---|---|---|---|---|---|
| `chromium` | macOS 原生 148 | CDP | `farm.js start --engine chromium` | `account, port, tz, lang, fp_seed` | canvas/WebGL/字体/UA-CH；**无 GPU 元数据** |
| `linux150` | Docker amd64（Rosetta/原生） | CDP | 容器 → `attach --cdp` | `account, cdp, tz, lang, seed` | 上述 + **GPU vendor/renderer**（需 `--use-angle=swiftshader --enable-unsafe-swiftshader` + `--fingerprint-gpu-*`） |
| `chrome` | 宿主 157 | CDP | `start --engine chrome` | `account, port, tz, lang` | **真实指纹**，Google 服务/DRM 可用 |
| `camoufox` | Firefox 158 worker | Playwright/Juggler | `start --engine camoufox`（仅登记）→ 网关按需调 `camoufox_worker.py --task` | `account, profile, tz, lang` | 深人设（媒体/语音）；**无 CDP**；`/v1/tasks` 可达 `goto/eval/shot/scan`；headless 实测可用 |

> `attach --seed` **只写台账，不改运行中的容器**。种子必须在 `docker run -e FP_SEED=` 时给定；台账里的 `fp_seed` 用于审计与 `dup` 追溯。
>
> **profile 路径按平台分区**：`start`/`attach` 给 `--platform amazon` 时 profile 落 `profiles/amazon/<account>/`；不给平台落 `profiles/_unsorted/<account>/`。平台段做字符净化，账号段保持原样（历史目录名带 `:`）。`GET /instances`、`GET /v1/sessions` 均支持 `?platform=` 过滤。

### 2.3 接入五步

```bash
# 1) 起引擎（三选一）
node farm.js start --account ACCOUNT --port PORT --tz TZ --lang LANG --engine chromium --fp-seed SEED --platform PLATFORM
docker run -d --name fp-ACCOUNT --platform linux/amd64 -p 127.0.0.1:PORT:9334 \
  -e FP_SEED=SEED -e TZ=TZ -e FP_LANG=LANG -v DATA_ROOT/ACCOUNT:/data IMAGE_TAG
node farm.js start --account ACCOUNT --engine camoufox --tz TZ --lang LANG --platform PLATFORM   # 只登记，不起进程

# 2) 登记（start 自动写；容器走 attach）
node farm.js attach --account ACCOUNT --cdp http://127.0.0.1:PORT --engine linux150 --tz TZ --lang LANG --seed SEED --platform PLATFORM

# 3) 门禁
FARM_IP_ECHO=IP_ECHO_ENDPOINT node farm.js check --account ACCOUNT
# 4) 去重
node farm.js dup
# 5) 交给 gateway
```

---

## 三、接口契约

### 3.1 清单

| # | 方法 | 路径 | 语义 | 幂等 |
|---|---|---|---|---|
| 1 | POST | `/v1/sessions` | 创建（起引擎 + 首检） | `Idempotency-Key` 必填 |
| 2 | GET | `/v1/sessions/{sid}` | 查询 | 是 |
| 3 | GET | `/v1/sessions` | 列表（按租户前缀过滤） | 是 |
| 4 | POST | `/v1/sessions/{sid}/tasks` | 执行任务 | 按 `task_id`（10 min TTL） |
| 5 | GET | `/v1/tasks/{task_id}` | 任务结果 | 是 |
| 6 | DELETE | `/v1/sessions/{sid}` | 销毁 | `Idempotency-Key` 必填 |
| 7 | GET | `/v1/health` | 网关 + 宿主 + 引擎 | 是 |
| 8 | POST | `/v1/fingerprint/verify` | 对应 `farm check` | 是 |
| 9 | GET | `/v1/fingerprint/duplicates` | 对应 `farm dup` | 是 |
| 10 | GET | `/v1/version` | 版本契约；带 `?require=x.y.z` 时校验最低版本 | 是 |

通用头：`Authorization: Bearer TOKEN`、`X-Tenant-Id: TENANT_ID`、`X-Request-Id`。

### 3.2 关键语义

- **会话主键**：`{tenant}:{account}`；`tenant` 只取 `X-Tenant-Id`，body 里的 `tenant` 字段忽略。
- **删除后查询**：`GET /v1/sessions/{sid}` 返回 **200 + `status: "stopped"`**（台账保留），不是 404。
- **任务幂等**：同 `task_id` 重复提交返回同一状态，不重复执行；结果保留 10 分钟。
- **引擎能力与传输**：`ENGINE_CAPS` 在 `contract.js`，四引擎声明 `transport`（`cdp` / `worker`）与实测可跑的任务子集。`camoufox` 走 worker 传输：`/v1/tasks` 的 `goto/eval/shot/scan` 由网关起一次 `camoufox_worker.py` 执行，结果按 `{ok:true, ...}` 与 CDP 通道同形（`goto` 已实测逐字相同）；该引擎不支持的其它任务返回 `422`，body 带 `supported` 列表。
- **版本契约**：农场版本号在 `package.json`（现 `1.1.0`），契约版本在 `contract.js`（`contract_version: 2`）。平台子模式包装之前用 `GET /v1/version?require=x.y.z` 校验，不足返回 `409 E_VERSION_REQUIRED`；离线用 `node contract.js check --require x.y.z`。
- **profile 分区**：`profiles/<platform>/<account>`，未声明平台落 `profiles/_unsorted/`；台账 `accounts.platform` 与两个列表接口的 `?platform=` 对齐。
- **health 的 `engines`**：不带 `?probe=1` 时 CDP 引擎按 control 面判 `up`/`down`，worker 引擎与需外部容器的引擎报 `unverified`；带 `?probe=1` 时 chromium/chrome 真起临时实例跑一次 `goto`；camoufox 真查 worker 解释器：同一条 check 里同时验 `import camoufox` 与 Python 版本，`sys.version_info[:2] == (3,13)` 才判 `up`（`check` 写 `import camoufox + Python 3.13`），非 3.13 直接判 `down`（`check: "camoufox 需 Python 3.13"`，`error` 写明当前解释器与版本）——只验 import 会在 3.14+/3.15 上假绿，那种环境能 import 但生成指纹会 `TargetClosedError`；linux150 仍 `unverified`。`degraded` 取值已退役。

### 3.3 示例（实测返回）

```json
POST /v1/sessions   Idempotency-Key: IDEM_KEY
{ "account": "a1", "engine": "chromium", "tz": "Asia/Tokyo", "lang": "ja-JP", "fp_seed": 9001 }
→ 201
{ "session_id": "t1:a1", "engine": "chromium", "cdp": "http://127.0.0.1:19400",
  "status": "running", "check": { "ok": true, "fails": [], "canvas": "05ee60c6" } }
```

```json
POST /v1/sessions/t1:a1/tasks
{ "type": "goto", "params": { "url": "https://example.com" } }
→ 202 { "task_id": "TASK_ID", "status": "queued" }

GET /v1/tasks/TASK_ID
→ 200 { "ok": true, "status": "succeeded",
        "result": { "ok": true, "url": "https://example.com/", "readyState": "complete" } }
```

```json
GET /v1/fingerprint/duplicates
→ 200 { "distinct_canvas": 2, "collisions": [], "ok": true }
```

### 3.4 错误码

| code | HTTP | 含义 |
|---|---|---|
| `E_BAD_REQUEST` | 400 | 字段缺失/未知引擎/未知任务类型 |
| `E_UNAUTH` | 401 | token 无效 |
| `E_TENANT_FORBIDDEN` | 403 | 跨租户 |
| `E_SESSION_NOT_FOUND` | 404 | 会话/任务不存在 |
| `E_ACCOUNT_BUSY` | 409 | 账号已有活跃会话 |
| `E_CANVAS_COLLISION` | 409 | `dup` 命中 |
| `E_UNSUPPORTED_TASK` | 422 | 引擎无 CDP 任务通道 |
| `E_FINGERPRINT_MISMATCH` | 424 | `check` 失败（带 `fails`） |
| `E_RATE_LIMITED` | 429 | 超 RPS |
| `E_QUOTA_EXCEEDED` | 429 | 超租户并发配额 |
| `E_ENGINE_UNAVAILABLE` | 502 | 引擎起不来 |
| `E_CDP_UNREACHABLE` | 502 | 无 cdp 端点/连不上 |
| `E_TASK_TIMEOUT` | 504 | 任务超时 |
| `E_INTERNAL` | 500 | 未分类 |

---

## 四、二次开发扩展点

| 扩展 | 改哪里 | 位置 | 说明 |
|---|---|---|---|
| 新引擎 | `farm.js` | 顶部 `ENGINES` | 加 `name: binaryPath` |
| | `gateway/server.js` | `ENGINE_CAPS` | 声明 `transport` 与支持的 `tasks` |
| | `control.js` | `POST /instances` 的 `args` | 新引擎特有时在此映射 |
| 新任务 | `driver.js` | `switch (cmd)` 分支 | 复用现有 CDP client |
| | `gateway/server.js` | `TASK_REGISTRY` | `type → argv` |
| 新指纹维度 | `farm.js` | `PROBE` 常量 | 加字段 |
| | `hardening/preflight.js` | 规则段 | 加 FAIL/WARN 判据 |
| | `ledger.js` | `checks` 表 + `recordCheck` | 加列或写 `raw` |
| | `farm.js` | `dup()` SQL | 改 `GROUP BY` 键（现为 `canvas`） |

```js
// gateway/server.js —— 新任务只需加一行
const TASK_REGISTRY = {
  goto: (p) => ['goto', '--url', String(p.url)],
  hover: (p) => ['hover', '--x', String(p.x), '--y', String(p.y)],   // 新增（driver 需同步加分支）
};

// gateway/server.js —— 新引擎能力声明
const ENGINE_CAPS = {
  chromium: { transport: 'cdp', tasks: ['goto','eval','click','type','shot','scan'] },
  linux150: { transport: 'cdp', tasks: ['goto','eval','click','type','shot','scan'] },
  chrome:   { transport: 'cdp', tasks: ['goto','eval','click','type','shot','scan'] },
  camoufox: { transport: 'worker', tasks: [] },
};
```

```js
// farm.js dup() —— 从单维扩到多维
const rows = ledger.db.prepare(`
  SELECT canvas || '|' || COALESCE(renderer,'') AS fp_key, COUNT(*) n, GROUP_CONCAT(account) accts
  FROM checks WHERE id IN (SELECT MAX(id) FROM checks GROUP BY account)
  GROUP BY fp_key HAVING n > 1
`).all();
```

---

## 五、对外服务与部署

### 5.1 拓扑

`EDGE_GW（TLS/JWT/限流） → dsbot-gateway ×2–4（无状态） → farm-control@H1/H2/H3（loopback） → 引擎`

### 5.2 鉴权 / 限流 / 隔离

| 项 | v1.1 实况 |
|---|---|
| 鉴权 | 网关 Bearer `TOKEN`；control 用 `x-farm-token`；JWT 在 EDGE_GW（阶段 2） |
| 限流 | **参考实现为单租户单桶 `RPS=50`**；"建会话 5 rps / 任务 50 rps"分桶列为阶段 2 |
| 配额 | `QUOTA`（默认 8）按租户前缀统计活跃会话，超限 429 |
| 租户隔离 | 主键 `{tenant}:{account}`；数据目录 `/DATA_ROOT/{tenant}/{account}` |
| 引擎隔离 | 一账号一进程/容器；容器 `--memory=1g --cpus=1 --shm-size=512m`（x86） |

### 5.3 容量规划（修正版）

公式：`并发 = min( floor((RAM_GB − 4) / 0.9 × 0.7), floor(cores × k) )`，`k=1.2`（原生）/ `k=0.6`（Rosetta）。

| 环境 | 内存 | CPU | 内存上限 | CPU 上限 | **建议并发** | 预热池 |
|---|---|---|---|---|---|---|
| macOS + Rosetta | 16 GB | 10 | 9 | 6 | **6** | 2 |
| macOS + Rosetta | 32 GB | 12 | 21 | 7 | **7** | 3 |
| x86 原生 | 16 GB | 8 | 9 | 9 | **8** | 3 |
| x86 原生 | 32 GB | 16 | 21 | 19 | **18** | 5 |
| x86 原生 | 64 GB | 32 | 46 | 38 | **36** | 8 |

基线：单实例**负载下 600–900 MB**、页面就绪 **~8 s**（Rosetta 冷启动 8–15 s）；预热池 = 峰值新建速率 × 8 s。

**实测（M5 / 24 GB，4 容器并发冷启动）**：

| 指标 | 实测 |
|---|---|
| CDP 就绪 | 3.8 / 4.1 / 4.2 / 4.2 s |
| 空闲 RSS | 423–469 MiB（满载才到 600–900 MiB） |
| 运行时 CPU | 空闲 <2%，单容器峰值 161%（Rosetta 模拟） |

### 5.4 部署命令

**macOS（Rosetta）**

```bash
docker build --platform linux/amd64 -t IMAGE_TAG ./docker
docker run -d --name fp-ACCOUNT --platform linux/amd64 -p 127.0.0.1:PORT:9334 \
  -e FP_SEED=SEED -e TZ=TZ -e FP_LANG=LANG -v DATA_ROOT/ACCOUNT:/data IMAGE_TAG
node farm.js attach --account ACCOUNT --cdp http://127.0.0.1:PORT --engine linux150 --tz TZ --lang LANG --seed SEED
FARM_IP_ECHO=IP_ECHO_ENDPOINT node farm.js check --account ACCOUNT
node farm.js dup && node control.js --port 19555 --token TOKEN
node gateway/server.js --port 19600 --controls http://H1:19555,http://H2:19555 --token TOKEN
```

**x86 Linux（原生）**

```bash
docker build -t IMAGE_TAG ./docker
docker run -d --name fp-ACCOUNT --memory=1g --cpus=1 --shm-size=512m -p 127.0.0.1:PORT:9334 \
  -e FP_SEED=SEED -e TZ=TZ -e FP_LANG=LANG -v DATA_ROOT/ACCOUNT:/data IMAGE_TAG
# 其余同 macOS
```

> 必带 `-e TZ=`：容器默认 UTC，缺它 `check` 直接 `tz` 失败（实测）。

---

## 六、风险与待闭合项

| # | 项 | 当前阻塞 | 临时替代 | 需方提供 | 闭合判定 |
|---|---|---|---|---|---|
| 1 | 真实出口 IP | api.ipify.org 不可达 | `FARM_IP_ECHO=http://127.0.0.1:19700/ip` 本地 echo，`check.probe.ip` 可断言 | 可出网代理 | 真代理下 `ip` 等于代理出口且与时区匹配 |
| 2 | 规模化机器 | 无 x86 主机 | macOS 单机 4–6 容器压测 | ≥16C/64G x86 | 36 并发 24h 无 OOM |
| 3 | DS-Bot 字段表 | 未提供 | 本文 `/v1` 为基线 | OpenAPI | 双向联调通过 |
| 4 | camoufox 任务通道 | 仅 SCAN，不读 stdin | 单账号人工/脚本调用 | 是否必须 Firefox 人设 | worker 支持 `goto/eval/shot` 任务 JSON |
| 5 | 全局 `dup` | **已闭合**：gateway `--controls H1,H2` 聚合 | 单机仍可直接 `farm.js dup` | 是否上 Postgres（扩容后） | 两宿主同种子 → 409；换种子 → 200（已实测） |
| 6 | 148 版本旧 | 上游稳定构建 | 关键账号用 linux150 | 是否接受 Rosetta | 全量账号 ≥150 |
| 7 | Docker Hub | 不可达 | `docker.m.daocloud.io` 镜像源 | 私有 registry | 构建不依赖公网 Hub |

---

## 七、验收标准

- [x] 四引擎在台账中 `engine` 分别为 `chromium`/`linux150`/`chrome`/`camoufox`
- [x] `check` 对 chromium 与 linux150 均通过，linux150 的 `webgl.renderer` 为伪造串
- [x] 不同 `fp_seed` 的会话 `dup` 返回 `collisions: []`
- [x] `POST /v1/sessions` 同 `Idempotency-Key` 重放返回同一 `session_id`，无第二个进程
- [x] 任务 `goto`/`eval` 在 chromium 上成功（`shot` 见 driver 单测）
- [x] camoufox worker 任务通道（`goto/eval/shot` 实测通过）
- [x] `DELETE` 后 `GET` 返回 `status=stopped`
- [x] `GET /v1/health` 区分 `up` / `degraded`（camoufox）
- [x] `check` 失败返回 424 并带 `fails`
- [x] 超配额返回 429
- [ ] x86 36 并发压测（需机器；macOS 4 容器基线已完成：3.8–4.2 s / 423–469 MiB）
- [x] 全文占位符化，无硬编码主机/密钥
