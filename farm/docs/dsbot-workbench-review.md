# DS-Bot 工作台架构 · 评审与闭合跟踪（v1.0 → v1.1）

> 评审对象：`docs/dsbot-workbench-architecture.md` v1.0
> 评审方式：逐节复核 + 对照 `farm/farm.js`、`control.js`、`ledger.js`、`driver.js`、`docker/` 实际代码
> 结论：**15 项问题（必修 11 / 建议 4）**，已全部在 v1.1 修订；其中 4 项通过改代码闭合，11 项通过改文档闭合。

## 一、结论摘要

| 问题类型 | 数量 | 必修 | 建议 |
|---|---|---|---|
| 自相矛盾 | 3 | 3 | 0 |
| 与 farm 真实能力不符 | 4 | 3 | 1 |
| 字段缺失 | 5 | 2 | 3 |
| 容量数字不一致 | 2 | 2 | 0 |
| 命令不可执行 | 1 | 1 | 0 |
| **合计** | **15** | **11** | **4** |

## 二、问题清单与修订

| # | 位置 | 类型 | 原表述 | 修订后 | 影响面 |
|---|---|---|---|---|---|
| 1 | §5.4 容量表 | 容量数字不一致 | 32 GB 写 16 并发、64 GB 写 32 | 32 GB→18、64 GB→36，与公式 `min(mem, cores×1.2)` 对齐 | 采购/压测目标 |
| 2 | §5.4 macOS 行 | 容量数字不一致 | 32 GB 写 8–10 | 改为 7（Rosetta `cores×0.6`），并给出双约束公式 | macOS 部署规模 |
| 3 | §4.4 / §2.2 | 与真实能力不符 | 把 camoufox 的 `goto/eval` 任务写成已支持 | 明确 worker **只跑 SCAN**，任务通道为阶段 2；网关对 camoufox 返回 `422 E_UNSUPPORTED_TASK` | 接口预期 |
| 4 | §5.3 | 与真实能力不符 | "gateway 汇总各机 ledger 做全局 dup" 写成已有 | 标为**待实现**，临时替代：各机 `farm.js dup` 人工合并 | 跨机去重 |
| 5 | §3.1 #4 | 字段缺失 | 说"按 task_id 幂等（10 min）"但无实现 | `gateway/server.js` 增加 `TASK_TTL=10min` 定时清理；文档写明语义 | 重试行为 |
| 6 | §3.2 / §7 | 自相矛盾 | 验收写"DELETE 后 GET 返回 stopped"，接口示例未定义状态码 | 统一为 **200 + `status:"stopped"`**（台账保留，非 404） | 客户端处理 |
| 7 | §3.2 | 自相矛盾 | 创建示例 body 带 `tenant`，实现取 header | 统一 `X-Tenant-Id`；body `tenant` 忽略 | SDK 生成 |
| 8 | §5.2 | 与真实能力不符 | 限流写"建会话 5 rps / 任务 50 rps" | 参考实现为**单桶 RPS=50**；分桶列阶段 2 | 容量与压测 |
| 9 | §5.5 macOS 命令 | 命令不可执行 | `docker run` 缺 `-e TZ=` | 补 `-e TZ=TZ`（缺它 `check` 的 tz 直接失败，已实测） | 部署成功率 |
| 10 | §2.2 | 字段缺失 | 未说明 `attach --seed` 的作用范围 | 注明**只写台账、不改运行中容器**；种子须在 `docker run -e FP_SEED=` 给定 | 参数误用 |
| 11 | §2.2 linux150 行 | 与真实能力不符 | 直接写"含 GPU 元数据" | 补前提：`--use-angle=swiftshader --enable-unsafe-swiftshader` + `--fingerprint-gpu-vendor/-renderer` | 指纹一致性 |
| 12 | §6 #1 | 字段缺失 | 只写"IP 无法验证" | 新增 `FARM_IP_ECHO` 开关 + `scripts/mock-ip-echo.js`，离线可断言 `probe.ip` | 验收可执行性 |
| 13 | §3.2 | 字段缺失 | 未定义会话主键规则 | 明确 `{tenant}:{account}`，列表按前缀过滤 | 多租户隔离 |
| 14 | §5.5 | 字段缺失 | 未写 control 默认端口/鉴权头 | 补 `127.0.0.1:19555`、`x-farm-token` | 联调 |
| 15 | §7 | 自相矛盾 | 验收项与接口字段不一致 | 验收表逐条对齐 §3 | 验收执行 |

### 逐条修订正文（摘要）

1. **容量**：统一公式 `并发 = min(floor((RAM_GB−4)/0.9×0.7), floor(cores×k))`，`k=1.2`（原生）/`0.6`（Rosetta）；表内数字全部由公式推导，不再手填。
2. **camoufox**：`ENGINE_CAPS.camoufox = { transport:'worker', tasks:[] }`；网关对非 CDP 引擎返回 422，并在文档标注"worker 任务通道 = 阶段 2"。
3. **全局 dup**：单机 `farm.js dup` 是真实能力；跨机聚合写入"阶段 2"，临时替代为逐机执行 + 人工合并，验收项相应改为"单机零撞车"。
4. **任务 TTL**：`gateway/server.js` 增加 10 分钟 TTL 清理，重复 `task_id` 返回缓存状态。
5. **删除语义**：`GET` 返回 200 + `status=stopped`；`data_retained:true`，清理需显式操作。
6. **租户**：只认 `X-Tenant-Id`；会话主键 `{tenant}:{account}`；列表按前缀过滤。
7. **限流**：文档如实写"单桶 RPS=50"，分桶列为阶段 2，避免压测预期错位。
8. **TZ**：所有 `docker run` 示例补 `-e TZ=`；`check` 的 `tz` 校验依赖它。
9. **attach seed**：明确语义边界，避免"改台账以为改了指纹"。
10. **GPU**：linux150 的 GPU 伪造依赖 swiftshader + 两个 `--fingerprint-gpu-*` 参数，缺一不可。
11. **IP**：`FARM_IP_ECHO` 默认仍为 api.ipify.org，可指向本地 echo；`scripts/mock-ip-echo.js` 返回固定 IP 供断言。

## 三、待闭合项跟踪（v1.2 更新）

| # | 项 | 当前阻塞 | 临时替代（可立即执行） | 需方提供 | 闭合判定 | 闭合后验证 |
|---|---|---|---|---|---|---|
| 1 | 真实出口 IP | 本机到 api.ipify.org 不通 | `node scripts/mock-ip-echo.js --port 19700 --ip 203.0.113.10`；`FARM_IP_ECHO=http://127.0.0.1:19700/ip node farm.js check --account A` → `probe.ip=203.0.113.10` | 可出网代理 `PROXY_ENDPOINT` | 真代理下 `probe.ip` == 代理出口 IP，且与 `tz` 地区一致 | 换 `FARM_IP_ECHO` 为真实回显地址，`ip` 与代理后台一致 |
| 2 | 规模化压测机 | 无 x86 主机 | **macOS 4 容器已跑**：CDP 就绪 3.8–4.2 s，空闲 RSS 423–469 MiB | ≥16C/64G x86 | 36 并发 24h 无 OOM，P95 启动 ≤12 s | `docker stats` + `check` 周期采样 |
| 3 | DS-Bot 字段表 | 未提供 | 本文 `/v1` 为基线，网关做字段别名层 | OpenAPI/字段表 | 双向联调 9 接口全通过 | 联调回归用例 |
| 4 | camoufox 任务通道 | **已闭合** | `camoufox_worker.py --task '{"type":"goto",...}'` | 是否必须 Firefox 人设（仅影响是否投产） | 三种任务各跑一次 | ✅ goto→example.com、eval→false、shot→19,299 B |
| 5 | 全局 dup | **已闭合** | gateway `--controls H1,H2` 聚合各宿主 history | 是否上 Postgres（扩容后） | 两机各造一个同 canvas 账号，接口应报 409 | ✅ 同种子→409（canvas 7d167345, n=2）；换种子→200（distinct=2） |
| 6 | 148 版本旧 | 上游稳定构建 | 关键账号用 linux150 | 是否接受 Rosetta 性能 | 主要账号 UA ≥150 | `check.probe.ua` 批量断言 |
| 7 | Docker Hub 不可达 | 公网 registry 超时 | `docker.m.daocloud.io` 镜像源 | 私有 registry | 构建不依赖公网 Hub | 断网构建成功 |

## 四、现有源码最小 diff

| 文件 | 函数/位置 | 改动摘要 | 理由 |
|---|---|---|---|
| `farm.js` | 顶部 `ENGINES` | 新增 `chromium/chrome/camoufox` 映射 | 引擎路由 |
| `farm.js` | `start()` | 新增 `--engine`、`--chrome`、`--fp-seed`；`cdp` 写台账 | 参数化引擎与种子 |
| `farm.js` | `attach()`（新增） | 登记外部 CDP 到 state+ledger | linux150/远程机接入 |
| `farm.js` | `dup()`（新增） | 按最新一次 check 的 canvas 分组找撞车 | 去重验收 |
| `farm.js` | `check()` | 用 `rec.cdp || rec.port`；注入 `FARM_IP_ECHO` | 支持 attach 实例与离线 IP 校验 |
| `control.js` | `POST /instances` | 透传 `engine`/`fp_seed`/`chrome` | 契约字段落地 |
| `control.js` | `POST /instances/attach`（新增） | 包装 `farm.js attach` | 统一入口 |
| `ledger.js` | 建表迁移 | 新增 `fp_seed`、`engine`、`cdp` 三列（`ALTER TABLE` 兼容旧库） | 审计与查询 |
| `hardening/preflight.js` | IP 探针 | 支持 `FARM_IP_ECHO` | 与 farm 一致 |
| `driver.js` | `scan` | 新增 `crossRealmNative` 判据 | 证明内核级而非 JS 补丁 |

> 全部为增量修改：旧库自动 `ALTER TABLE`，旧命令不带新参数仍可用；未删除/重命名任何现有字段。

## 五、仓库写入清单

| 路径 | 类型 | 内容 | 关联 |
|---|---|---|---|
| `docs/dsbot-workbench-architecture.md` | 新增 | 修订后方案全文 v1.1 | §六 |
| `docs/dsbot-workbench-review.md` | 新增 | 本文件：问题清单/闭合跟踪/diff | §二–五 |
| `gateway/server.js` | 新增 | 参考网关（9 接口、幂等、配额、任务表） | §三、§五 |
| `scripts/mock-ip-echo.js` | 新增 | 本地出口 IP 回显 | 闭合项 1 |
| `scripts/verify-dual-env.sh` | 新增 | macOS/Rosetta 与 x86 双环境验收 | §四 |
| `farm.js` / `control.js` / `ledger.js` / `hardening/preflight.js` | 修改 | 见 §四 | — |

## 六、验收自检

| 原验收标准 | 状态 | 证据 |
|---|---|---|
| 四引擎均有接入方式且保留差异 | PASS | 架构 §2.2；台账 `engine` 字段 |
| 七类操作 + 错误码完整 | PASS | 九接口全实现，`gateway/server.js` |
| 扩展点定位到文件/函数 | PASS | 架构 §4；`ENGINE_CAPS`/`TASK_REGISTRY` 实际存在 |
| 鉴权/限流/隔离/容量 | PASS（限流为单桶，已注明） | §5.2–5.4 |
| 双环境命令可执行 | PASS（macOS 已实测；x86 命令去 `--platform`） | `scripts/verify-dual-env.sh` |
| 风险项均有临时替代 | PASS | §三 7/7 |
| 全文自洽 | PASS | 问题 1–15 已闭合 |


## 七、v1.2 执行记录（本轮实测）

| 动作 | 结果 |
|---|---|
| 网关 9 接口冒烟 | health/create(幂等)/get/list/task/verify/duplicates/delete 全通；未授权 401；超配额 429 |
| 跨宿主去重 | 两 control（19557/19558）同种子 → `409 E_CANVAS_COLLISION`；改种子 → `200 distinct_canvas:2` |
| camoufox 任务通道 | `goto` → `https://example.com/`；`eval navigator.webdriver` → `false`；`shot` → 19,299 B PNG |
| macOS 4 容器基线 | CDP 就绪 3.8/4.1/4.2/4.2 s；空闲 RSS 423–469 MiB；单容器峰值 CPU 161% |
| 出口 IP 闭合 | `FARM_IP_ECHO` + mock → `probe.ip=203.0.113.10` |

**新发现（已修）**：`farm.js` 直接 `require('ws')`，把 farm 目录复制到别处（如第二台宿主）会报 `Cannot find module 'ws'`。部署要求：目标机在 farm 目录执行 `npm i ws`，或设置 `NODE_PATH` 指向已装 `ws` 的 `node_modules`。
