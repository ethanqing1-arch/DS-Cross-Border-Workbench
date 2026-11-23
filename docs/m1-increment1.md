# M1 增量 1：任务契约补 extract / wait + health 真探针

日期：2026-11-23
范围：只做计划第 2 节的前两件（补两类任务、健康探测改真）。profile 分区、版本契约、camoufox 一等引擎均未动。
改动文件：`farm/driver.js`、`farm/gateway/server.js`。未加 npm 依赖，未动 `control.js` 路由，未改现有 6 类任务签名。

## 1. 改动清单

### driver.js

| 行 | 改动 |
|---|---|
| `:28-29` | `OPTS` 新增 `--selector-map`、`--timeout`、`--selector`、`--state`、`--timeout-ms`，否则子命令识别会把选项值当成命令名 |
| `:103-138` | 新增 `extract` 分支：可选 `--url` 先导航并等 `readyState=complete`；然后按 `--selector-map` 逐个 `document.querySelector` 取 `textContent.trim()`，缺失字段在超时前每 200ms 重试；输出 `{ok,url,fields,missing}` |
| `:139-155` | 新增 `wait` 分支：`--selector` + `--state present|absent` + `--timeout-ms`（默认 30000），200ms 轮询；输出 `{ok,selector,state,found,waited_ms}` |
| `:138` | `extract` 字段缺失不再让进程退出码非 0（`ok` 字段已表达）；硬失败只剩导航超时/参数错误 |

请求/返回契约（经网关 `/v1/sessions/:sid/tasks`）：

```
POST {"type":"extract","params":{"url":"https://.../页","selector_map":{"title":"title","h1":"h1"},"timeout_ms":15000}}
→ result {"ok":true,"url":"...","fields":{"title":"...","h1":"..."},"missing":[]}

POST {"type":"wait","params":{"selector":"#result","state":"present","timeout_ms":10000}}
→ result {"ok":true,"selector":"#result","state":"present","found":true,"waited_ms":12}
```

### gateway/server.js

| 行 | 改动 |
|---|---|
| `:55-57` | `TASK_REGISTRY.extract`：拼 `extract --selector-map <json> [--url ...] [--timeout ...]` |
| `:58-59` | `TASK_REGISTRY.wait`：拼 `wait --selector ... --state ... --timeout-ms ...` |
| `:63` | `PROBE_ENGINES = ['chromium','chrome']`（可 provision 的 CDP 引擎） |
| `:64-84` | `probeEngine(engine)`：先 DELETE 清残留，再 `POST /instances` 起 headless 临时实例（固定账号 `probe:health:<engine>`），用 `process.execPath` 跑 `driver goto about:blank`，finally 里 DELETE 销毁 |
| `:166-186` | `/v1/health` 增加 `?probe=1`（也接受 `true`）：不探测时原样返回；探测时 `ok = control up && 所有探针 ok`，`engines` 用探针结果，linux150 标 `unverified`，camoufox 保持 `degraded`，并附 `probe:{at,engines:{...}}` |
| `:286` | 任务失败时 error 优先取 stderr，其次 stdout（避免 driver 的结构化输出被吞），最后 message |

## 2. 验收

### 2.1 自检

命令（先 `--stop` 真网关，再 full access 跑，最后 `--daemon` 起回）：

```
bash scripts/start-gateway.sh --stop
bash scripts/acceptance.sh --with-browser
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash scripts/start-gateway.sh --daemon
```

原文（末尾）：

```
== 6. 真机冒烟（起 chromium + 首检 + 任务）==
  PASS check 通过

== 汇总: PASS=31 FAIL=0 WARN=0 ==
RESULT: READY
```

（section 5 同轮：`PASS gateway /v1/health`、`PASS 未授权返回 401`、`PASS duplicates 可调用`。）

### 2.2 extract 手动验收

`https://example.com` 已改版，页面里只有一段说明文字、没有 `<h1>`（实测 `h1 count: 0`、`querySelector("h1") → null`），属页面变更，不是 extract 缺陷。改用 `https://www.iana.org/help/example-domains`：

```
POST /v1/sessions/default:m1-extract2/tasks
{"task_id":"m1-extract-2","type":"extract","params":{"url":"https://www.iana.org/help/example-domains","selector_map":{"title":"title","h1":"h1"},"timeout_ms":15000}}
```

任务结果原文：

```json
{
    "ok": true,
    "task_id": "m1-extract-2",
    "status": "succeeded",
    "result": {
        "ok": true,
        "url": "https://www.iana.org/help/example-domains",
        "fields": {
            "title": "Example Domains",
            "h1": "Example Domains"
        },
        "missing": []
    }
}
```

### 2.3 wait 手动验收

```json
{"ok":true,"task_id":"m1-wait-1","status":"succeeded","result":{"ok":true,"selector":"body","state":"present","found":true,"waited_ms":1}}
{"ok":true,"task_id":"m1-wait-2","status":"succeeded","result":{"ok":true,"selector":"#no-such-element","state":"absent","found":false,"waited_ms":1}}
```

### 2.4 health 真探针

停掉所有实例后。

不带 probe（原行为）：

```json
{"ok":true,"gateway":"up","control":"up","hosts":[{"control":"http://127.0.0.1:19555","control_status":"up","running":0}],"engines":{"chromium":"up","linux150":"up","chrome":"up","camoufox":"degraded"}}
```

带 `?probe=1`：

```json
{"ok":true,"gateway":"up","control":"up","hosts":[{"control":"http://127.0.0.1:19555","control_status":"up","running":0}],"engines":{"chromium":"up","linux150":"unverified","chrome":"up","camoufox":"degraded"},"probe":{"at":"2026-11-23T03:20:31.454Z","engines":{"chromium":{"ok":true,"ms":903,"cdp":"http://127.0.0.1:19400"},"chrome":{"ok":true,"ms":895,"cdp":"http://127.0.0.1:19400"}}}}
```

### 2.5 网关端点

```
/v1/health: {"ok":true,"gateway":"up","control":"up",...}
/v1/sessions 无 token: 401
/v1/sessions 真 token: 200
status: control: up pid=7318 / gateway: up pid=7321
```

## 3. 缺口（单列）

1. `?probe=1` 仍是无鉴权端点（按现有 health 契约），可以触发起浏览器。建议后续给 probe 加 token 门，属接口变更，本轮没动。
2. 探针会写台账：固定账号 `probe:health:chromium` / `probe:health:chrome` 每次复用（stopped），并在 `profiles/` 下建同名 profile 目录；不是零副作用。
3. 探针只覆盖可 provision 的 CDP 引擎；linux150（需外部容器）标 `unverified`，camoufox（worker）保持 `degraded`，两者未真探。
4. 并发两个 `?probe=1` 会争同一个固定账号（预清理+创建可能互踩），当前按单次调用设计。
5. probe 模式 `engines` 出现新值 `unverified`；只在带 probe 时出现，不带 probe 的契约未变。
6. 任务失败时 `error` 仍是字符串（已带 stdout），不是结构化 result；`wait` 超时走 `status=failed`，调用方要从 error 文本里读 JSON。
7. 手动验收在真台账留下 4 个 stopped 测试账号（m1-extract / m1-dbg / m1-dbg2 / m1-extract2）与 4 条体检记录，未清理。
8. acceptance 收尾删临时目录时 Chromium 还在写 profile，出现 `rm: .../profiles/acc-smoke: Directory not empty`，不影响 RESULT。
9. `GATEWAY_TOKEN` 仍是 8 位（启动提示每次出现），令牌轮换仍待用户操作。
