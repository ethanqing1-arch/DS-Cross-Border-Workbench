# Codex 开发交接单：farm 剩余 5 项

写给要接手 `farm/` 开发的 Codex。每项的现状都按 2026-11-24 的代码实测写，行号对应当前 `main`。
不要把本单当成愿望清单 —— 7 项里有 2 项已经不需要做了，见 §3。

---

## 0. 边界（先读，违反会坏东西）

| 项 | 值 |
|---|---|
| 仓库 | `/Users/xavier/Projects/DS-Cross-Border-Workbench`（git，分支 `main`） |
| 代码根 | 上条路径下的 `farm/` |
| 运行宿主 | DS Bot。`farm/gateway/server.js` 是 REST 网关，`farm/mcp/farm-mcp.js` 把它包成 MCP |
| 改完必须跑 | `farm/scripts/acceptance.sh --with-browser` |

**绝对不要动：**

- `farm/profiles/`、`farm/state/`、`farm/farm.db` —— 含登录态 Cookie 与运营数据，已在 `.gitignore`。清理类任务不在本单。
- 任何 secret。令牌只从 `GATEWAY_TOKEN` / `$DSH_SECRET_GATEWAY_TOKEN` 读，**不要写进任何文件、不要进 argv**。
- launchd、系统设置、密码库、DS Bot 自身。

**现在有活的东西在跑，别顺手停：**

```
gateway  19671  pid 22662
control  19555  pid 22659
实例 default:mkt-probe-amazon  status=running  pid 23934  (/Applications/fingerprint-chromium.app/...)
```

`acceptance.sh` 默认占 `19671`（真部署端口），**不要用它默认值** —— 那会要求你先停真网关，
而现在有别的东西在跑。用备用端口跑：

```bash
cd /Users/xavier/Projects/DS-Cross-Border-Workbench/farm
ACCEPT_PORT=19971 ACCEPT_CONTROL_PORT=19871 bash scripts/acceptance.sh --with-browser
```

**不在本单的外部条件**（做了也没法验）：目标国出口代理、7 平台官方 API 授权、Docker/linux150、
`GATEWAY_TOKEN` 换 ≥32 位、真实店铺账号。这些不是代码问题。

---

## 1. 总验收闸

```bash
cd /Users/xavier/Projects/DS-Cross-Border-Workbench/farm
ACCEPT_PORT=19971 ACCEPT_CONTROL_PORT=19871 bash scripts/acceptance.sh --with-browser
cd .. && bash distribution/verify.sh         # 记 PASS=61 FAIL=0 WARN=0 / READY
```

**不要用 `acceptance.sh` 的默认端口**：它默认 `19671`，会要求先停真网关，
而那上面有别的东西在跑（见 §0）。用上面这对备用端口，19971/19871 已确认空闲。

两个数字都是 2026-11-23 的快照，**以脚本实际输出为准**；但 FAIL 必须为 0。
每项任务单独一个 commit，别把 5 项混成一坨 —— 混了以后哪项把验收弄红就分不清了。

---

## 2. 任务（按建议顺序）

### T1 · worker 通道补出口 IP 探测（最小，先做这个热身）

**现状**：camoufox 走 worker 传输时，体检结果里 IP 恒为 null，理由写死在代码里：

```js
// farm/farm.js  camoufoxScan()
return {
  ...
  ip: null, ipErr: 'worker 通道未做 IP 探测',
  engine: 'camoufox',
};
```

对照 CDP 通道 `cdpScan()`，它把 `FARM_IP_ECHO`（默认 `https://api.ipify.org?format=json`）注入页面再读回。

**改成什么**：在 `camoufox_worker.py` 的 `scan` 分支里，用同一个 `FARM_IP_ECHO` 地址取一次出口 IP，
把结果放进 `result.probe.ip` / `result.probe.ipErr`；`farm.js` 的 `camoufoxScan` 改成透传这两个字段，
删掉写死的 `ipErr` 字面量。**要与 CDP 通道读同一个环境变量、同一个默认地址**，否则「同形」是假的。

**验收**：

```bash
# 无代理时应拿到真实出口 IP 或一个明确错误，不能是「未做 IP 探测」
curl -sS -H "Authorization: Bearer $GATEWAY_TOKEN" \
  http://127.0.0.1:19671/v1/sessions/<camoufox账号> | head -c 400
```

**风险**：离网时 IP 接口会超时。必须把它限制在体检已有超时内，且失败只记 `ipErr`，
**不能让整个 scan 失败** —— 现在 CDP 通道就是这个语义。

---

### T2 · `eval` 的返回形状跨引擎对齐（`shot` 已同形，别改）

**现状**：`goto` 在两种引擎上逐字相同；`eval` 不同，根因在 CDP 侧。

```js
// farm/driver.js:168  eval 分支
} else if (cmd === 'eval') {
  const expr = val('expr');
  const v = await c.evalJS(expr);
  console.log(typeof v === 'string' ? v : JSON.stringify(v, null, 2));   // ← 打印裸值，没有 {ok} 信封
}
```

网关按 `JSON.parse(stdout)` 兜底（`farm/gateway/server.js:402`）：

```js
let out; try { out = JSON.parse(stdout); } catch (e) { out = { raw: stdout.slice(0, 2000) }; }
```

于是同样一次 eval：

- CDP → 字符串值是裸字符串，`JSON.parse` 多半失败，落到 `{ raw: "..." }`
- worker → `Object.assign({ ok: true }, j.result)`（`server.js:85`），`j.result` 是 `{'value': ...}`，
  最终 `{ ok: true, value: ... }`

**改成什么**：以 `{ ok: true, value: <原值> }` 为唯一形。`driver.js` 的 eval 分支统一 `console.log(JSON.stringify({ ok: true, value: v }))`；
`camoufox_worker.py` 的 `eval` 已经把值放在 `result.value`，网关的摊平逻辑不用动。
顺便确认 `shot`：CDP 是 `{ok,path,bytes}`（`driver.js:196`），worker 摊平后也是 `{ok,path,bytes}`，**这条已经同形，不要改**。

**验收**：同一个表达式两次调用，`result` 逐字相同。取一个对象值和一个字符串值各测一遍
（字符串值才是现在踩坑的那条路径）：

```bash
# 两个引擎各跑一次，比较 result
POST /v1/sessions/<sid>/tasks  {"type":"eval","params":{"expr":"1+1"}}
POST /v1/sessions/<sid>/tasks  {"type":"eval","params":{"expr":"document.title"}}
```

**风险**：`eval` 的结果可能不合法 JSON（函数、循环引用）。`JSON.stringify` 会抛或不产出，要兜住并给出结构化错误，
不要让 gateway 落到 `{raw}` 这条静默路径。

---

### T3 · 任务失败时的 `error` 从字符串收敛成结构化对象

**现状**：`error` 全是 `String(...).slice(0, 800)`，三处：

```js
// farm/gateway/server.js
:387  .catch((e) => tasks.set(taskId, { status: 'failed', error: String(e.message || e).slice(0, 800), at: Date.now() }));
:405  .catch((e) => tasks.set(taskId, { status: 'failed', error: (String(e.stderr || '').trim() || String(e.stdout || '').trim() || String(e.message)).slice(0, 800), at: Date.now() }));
:411  return send(res, 200, { ok: t.status !== 'failed', ..., error: t.error });
```

调用方拿到的是一句话，分不清是引擎不支持、超时、还是页面被拦 —— 得靠正则猜。

**改成什么**：失败态统一成 `{ code, message, detail? }`。
`code` 用现有错误码词表（`E_UNSUPPORTED_TASK`、`E_TIMEOUT`、`E_WORKER_NO_OUTPUT`、
`E_CDP_UNREACHABLE`、`E_GOTO`…），`message` 保留现在那句话不丢信息。
`GET /v1/tasks/:id` 保持 `error` 字段名不变，但值从字符串变成对象。

**兼容性要求**：这是一次破坏性变更。**同一 commit 里**同步改 `mcp/farm-mcp.js` 的消费侧与
`scripts/acceptance.sh` 里断言 `error` 是字符串的用例，否则验收会红。
`contract.js` 的 `CONTRACT_VERSION` 要 +1（现在是 2）。

**验收**：造三种失败各一次（不支持的 task type、离网 goto、worker 无输出），
`error.code` 分别命中，且 `message` 仍可读。

---

### T4 · 探针不要留下台账与 profile 副作用

**现状**：`/v1/health?probe=1` 的 `probeEngine()` 是拿一个真账号去建实例：

```js
// farm/gateway/server.js:112
async function probeEngine(engine) {
  const account = `probe:health:${engine}`;
  await control('DELETE', `/instances/${encodeURIComponent(account)}`).catch(() => {});   // 先清残留
  const r = await control('POST', '/instances', { account, engine, tz: 'UTC', lang: 'en-US', headless: true });
  ...
  } finally {
    if (created) await control('DELETE', `/instances/${encodeURIComponent(account)}`).catch(() => {});
  }
```

DELETE 只停进程，台账行和 `profiles/probe:health:<engine>/` 目录都留着 —— 每探一次留一条。

**改成什么**：让探针用不落盘的模式。两条路，选一条并在 PR 说明里写清为什么：

1. `control` 侧给 `/instances` 加 `ephemeral: true`：不写台账、profile 落 `mktemp` 并在 DELETE 时删。
2. 探针改用独立的最小实例路径（`driver.js` 直接起临时 Chromium，不经台账）。

优先 1，因为它同时修好了「探针写台账」和「profiles 里全是 probe:* 目录」两个症状。
`probeWorkerCap()` 只 import 模块、不起浏览器，**不用改**。

**验收**：

```bash
before=$(FARM_DB=farm/state/farm.db node farm/ledger.js stats)
curl -sS -H "Authorization: Bearer $GATEWAY_TOKEN" 'http://127.0.0.1:19671/v1/health?probe=1'
after=$(FARM_DB=farm/state/farm.db node farm/ledger.js stats)
# accounts 计数必须相等；farm/profiles/ 下不得新增 probe:health:* 目录
```

**风险**：`?probe=1` 是免鉴权端点里唯一会起浏览器的分支，改动要确保 401 分支（`server.js:240-244`）
仍然在起实例**之前**生效。

---

### T5 · camoufox 常驻 worker（最大，最后做）

**现状**：每个任务起一个 Python 进程、跑完就关，Firefox 每次冷启。两处都是：

```js
// farm/farm.js:212        runWorker()    —— 体检（scan）走这条
const p = spawn(CAMOUFOX_PY, args, { stdio: ['pipe', 'pipe', 'pipe'] });

// farm/gateway/server.js:63 runWorkerTask() —— 任务（goto/eval/shot/scan）走这条
const p = spawn(CAMOUFOX_PY, args, { stdio: ['pipe', 'pipe', 'pipe'] });
```

实测建会话（含首检）约 8 秒，大头是每次重起 Firefox。

**改成什么**：按账号维护一个常驻 worker 进程（一个账号一个），用行分隔 JSON 双向通信；
进程空闲 N 分钟自杀；`DELETE /v1/sessions/:id` 要能把它一起收掉。
`runWorker` 与 `runWorkerTask` 应该收敛成一个客户端，不要再有两套 spawn 逻辑。

**这一项不要把交接单当设计**：常驻进程的生命周期、崩溃重启、并发同账号任务排队、
worker 与 `farm.js` 的职责边界，都需要先写一段设计再动手。**先交设计，不要直接改代码。**

**验收**：

```bash
# 同一 camoufox 会话连跑 3 个 goto，第 2、3 次应显著快于第 1 次
for i in 1 2 3; do /usr/bin/time -p curl -sS ... ; done
# 杀掉网关后不得留下孤儿 python 进程
```

**风险**：常驻进程泄漏、账号 profile 被两个进程同时打开（camoufox 会锁）、
网关重启后旧 worker 变孤儿。这三条任何一个没处理，都会让「一次任务一进程」这个
虽然慢但很稳的现状变差。

---

## 3. 已经从本单删掉的两项（不要做）

| 原缺口 | 实测结论 |
|---|---|
| `/v1/health?probe=1` 无鉴权 | **已修**。`farm/gateway/server.js:240-244`：`probe=1` 分支单独校验 Bearer，不匹配返回 `401 E_UNAUTH`；health 本体仍免鉴权。别重复实现。 |
| 台账里 4 个 stopped 测试账号待清理 | **不适用**。台账现在是 3 个账号，且 `default:mkt-probe-amazon` 是 `running`（pid 23934，fingerprint-chromium 在跑），有其他任务在用。清理不是开发任务，也不该由本单做。 |

---

## 4. 交付要求

- 每项一个 commit，标题按仓库既有风格：`fix(farm): …` / `feat(farm): …`。
- 每个 commit 里写清：改了什么、验收命令与**原文输出**、还差什么。
- 失败就如实写失败，不要用「应该可以」结案。
- 碰 `contract.js` 的（T3）必须同步升 `CONTRACT_VERSION` 并在 commit 里说明兼容性影响。

---

## 5. 跑完收尾

按 §1 用备用端口跑的话，真网关全程没动，**这一步跳过**。

只有在你确实停过真网关（例如手工排查）时才需要起回来：

```bash
cd /Users/xavier/Projects/DS-Cross-Border-Workbench/farm
CAMOUFOX_PY="$HOME/.dsh/venvs/camoufox/bin/python" \
  GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" \
  bash scripts/start-gateway.sh --daemon
bash scripts/start-gateway.sh --status
```

期望 `control: up pid=…` 与 `gateway: up pid=…`。
`CAMOUFOX_PY` 不设也能起（脚本会探测 `~/.dsh/venvs/camoufox`），但显式给更稳。
