# M1 增量 2：profile 按平台分区 + 版本契约 + Camoufox 一等引擎

日期：2026-11-23
范围：计划第 2 节六件事里的第 3、5、6 件。第 2、4 件已在增量 1 完成（`docs/m1-increment1.md`），第 1 件（封成 DSH capability）未动。
改动文件：`farm/farm.js`、`farm/control.js`、`farm/gateway/server.js`、`farm/camoufox_worker.py`、`farm/package.json`、`farm/scripts/acceptance.sh`，新增 `farm/contract.js`。未加 npm 依赖，未动 `driver.js`，未改现有任务签名。

## 1. 改动清单

### contract.js（新增）
| 位置 | 内容 |
|---|---|
| `:23` | `CONTRACT_VERSION = 2`：任务形状/错误码的兼容性边界 |
| `:26` | `TASK_TYPES` 八类（增量 1 的 `extract`/`wait` 并入） |
| `:33-38` | `ENGINE_CAPS` 四引擎唯一事实源；camoufox 改为 `transport:'worker'` + `tasks:['goto','eval','shot','scan']` |
| `:41` | `ATTACH_ONLY = ['linux150']` |
| `:60-70` | `contract()` 返回完整契约 |
| `:73-92` | `parse/cmp/check`：semver 三段朴素比较，不引依赖 |
| CLI | `node contract.js` / `check --require x.y.z` / `engines` / `tasks` |

### farm.js
| 行 | 改动 |
|---|---|
| `:51-52` | 新增 `safeSeg` / `profileDirFor`：profile 落 `profiles/<platform>/<account>`，未声明平台落 `profiles/_unsorted/`；平台段净化掉 `\ / : * ? " < > \|` 与控制字符，账号段保持原样（历史目录名带 `:`，改了会丢 Cookie） |
| `:101` | `start` 用 `profileDirFor(account, platform)` 取代原来的 `PROFILES/account` |
| `:111` | 引擎校验放行 `camoufox`（原来 `ENGINES.camoufox` 是空串，被 falsy 判断挡在 worker 分支之前） |
| `:118-132` | `--engine camoufox` 不再 `exit 2`，改为**只登记**：写 `state/<account>.json`（`mode:'worker'`、`cdp:null`）与台账，不起进程 |
| `:136` | state 记录补 `platform` |
| `:212-234` | 新增 `runWorker`：spawn `CAMOUFOX_PY camoufox_worker.py --task -`，任务走 stdin，取 stdout 最后一行 JSON |
| `:236-248` | 新增 `camoufoxScan`：把 worker 的 probe 映射成 CDP probe 同形字段 |
| `:250-257` | `cdpScan`：原 CDP 体检逻辑抽出 |
| `:259-267` | `judge`：体检判据两个通道共用（webdriver/tz/lang/canvas stable/toDataURL native） |
| `:279` | `check` 按 `engine==='camoufox' \|\| mode==='worker'` 分流 |
| `:236-248` 附注 | worker 通道不探测出口 IP，`ip` 恒为 null、`ipErr` 写明原因 |

### control.js
| 行 | 改动 |
|---|---|
| `:99-101` | `GET /instances` 支持 `?platform=`，返回体带 `platform` 回显 |
| `:132` | `/instances/attach` 透传 `--platform`（attach 不建 profile，但台账要能按平台筛） |

### gateway/server.js
| 行 | 改动 |
|---|---|
| `:38-39` | `ENGINE_CAPS`/`ATTACH_ONLY` 从 `../contract` 取，网关不再自持一份能力表 |
| `:63-88` | 新增 `runWorkerTask`：worker 引擎的任务走 `camoufox_worker.py`，结果 `{ok:true, ...j.result}` 对齐 CDP 通道形状 |
| `:92-102` | 新增 `probeWorkerCap`：用 `importlib.metadata.version("camoufox")` 判 worker 解释器可用 |
| `:212` | 不带 probe 时 worker 引擎报 `unverified`（原为 `degraded`，已不成立） |
| `:221-224` | `?probe=1` 增加 camoufox 探针，`engines.camoufox` 由探针结果决定 up/down |
| `:230-233` | 其它引擎仍标 `unverified`，`degraded` 取值从代码里消失 |
| `:247-257` | 新增 `GET /v1/version`（需鉴权）：无 `?require` 返回契约，带 `?require=x.y.z` 且不满足时 409 `E_VERSION_REQUIRED` |
| `:286,292,308` | `POST /v1/sessions` 透传/回显 `platform` |
| `:319-324` | `GET /v1/sessions` 支持 `?platform=` |
| `:340-352` | 任务分支按 `caps.transport` 分流：`worker` → `runWorkerTask`；引擎不支持该任务时 422 带 `supported` 列表 |

### camoufox_worker.py
| 行 | 改动 |
|---|---|
| `:96-103` | `goto` 结果补 `readyState`（`page.evaluate('document.readyState')`），与 CDP 通道同形 |

### 其它
- `package.json`：`version` 0.0.0 → **1.1.0**（此前没有任何版本号，版本契约无从校验）。
- `scripts/acceptance.sh`：文件清单补 `contract.js`；能力声明段改查 `contract.js` 并新增 4 项（网关接契约、worker 通道、profile 分区、版本自洽/判否）；`/v1/version` 三项（可用、需鉴权、不满足 409）；真机段加 `platform` 与两项筛选用例；收尾删除临时目录改为重试，消掉 `Directory not empty`。

## 2. 验收

### 2.1 自检

```
bash scripts/acceptance.sh --with-browser     # ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581
```

原文（末尾）：

```
== 6. 真机冒烟（起 chromium + 首检 + 任务）==
  PASS check 通过
  PASS profile 按平台分区（profiles/accplat/acc-smoke）
  PASS 台账按 platform 可筛
  PASS 无关平台筛不到

== 汇总: PASS=44 FAIL=0 WARN=0 ==
RESULT: READY
```

`rm: ... Directory not empty` 不再出现（增量 1 缺口 #8 闭合）。

### 2.2 版本契约

```
$ node contract.js check --require 1.0.0
{ "ok": true, "name": "ziniao-farm", "version": "1.1.0", "required": "1.0.0", "contract_version": 2 }   # exit=0

$ node contract.js check --require 1.2.0
{ "ok": false, "name": "ziniao-farm", "version": "1.1.0", "required": "1.2.0", "contract_version": 2 }  # exit=1
```

### 2.3 camoufox 真跑（worker 直调）

```
$ /tmp/cfx313/bin/python camoufox_worker.py --account cf-test --profile /tmp/cfxprof/cf13 \
    --tz Asia/Tokyo --lang ja-JP --headless --task '{"type":"scan"}'
{"ok": true, "account": "cf-test", "engine": "camoufox", "type": "scan", "result": {"probe": {
 "ua": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:158.0) Gecko/20100101 Firefox/158.0",
 "platform": "MacIntel", "language": "ja-JP", "languages": ["ja-JP", "ja"],
 "tz": "Asia/Tokyo", "tzOffsetMin": -540, "webdriver": false, "hc": 10, "dm": null,
 "canvas": {"hash": "ce646d53", "stable": true},
 "webgl": {"vendor": "Apple", "renderer": "Apple M1, or similar"},
 "fonts": ["PingFang SC", "Hiragino Sans GB", "Menlo", "Arial"], "plugins": 5,
 "mediaDevices": false, "toDataURL": "function toDataURL() {\n    [native code]\n}"}}}
```

### 2.4 网关侧 camoufox 会话（走 `/v1/*`，未碰 CLI）

```
POST /v1/sessions  {"account":"cf1","engine":"camoufox","tz":"Asia/Tokyo","lang":"ja-JP","platform":"ebay"}
→ 201
{"session_id":"default:cf1","engine":"camoufox","platform":"ebay","cdp":null,
 "tz":"Asia/Tokyo","lang":"ja-JP","fp_seed":null,"status":"running",
 "check":{"ok":true,"fails":[],"canvas":"ce646d53"},"created_at":"2026-11-23T03:36:03.617Z"}

real 0m7.949s      # 含首检（起一次 Firefox）
```

### 2.5 同一个 goto 两种引擎同形

```
POST /v1/sessions/default:cr1/tasks {"task_id":"t-cr-goto","type":"goto","params":{"url":"https://example.com"}}
→ {"task_id":"t-cr-goto","status":"queued"}
GET /v1/tasks/t-cr-goto
→ {"ok":true,"task_id":"t-cr-goto","status":"succeeded",
   "result":{"ok":true,"url":"https://example.com/","readyState":"complete"}}

POST /v1/sessions/default:cf1/tasks {"task_id":"t-cf-goto","type":"goto","params":{"url":"https://example.com"}}
→ {"task_id":"t-cf-goto","status":"queued","transport":"worker"}
GET /v1/tasks/t-cf-goto
→ {"ok":true,"task_id":"t-cf-goto","status":"succeeded",
   "result":{"ok":true,"url":"https://example.com/","readyState":"complete"}}
```

两条 `result` 逐字相同。

### 2.6 平台分区与筛选

```
profiles/amazon/default:cr1
profiles/ebay/default:cf1

GET /v1/sessions?platform=ebay   → {"platform":"ebay",  "accts":["default:cf1"], "platforms":["ebay"]}
GET /v1/sessions?platform=amazon → {"platform":"amazon","accts":["default:cr1"], "platforms":["amazon"]}
```

### 2.7 health 真探针（带 camoufox）

```
GET /v1/health?probe=1        real 0m2.046s
{"ok":true,"version":"1.1.0","contract_version":2,
 "engines":{"chromium":"up","linux150":"unverified","chrome":"up","camoufox":"up"},
 "probe":{"at":"2026-11-23T03:36:18.417Z","engines":{
   "chromium":{"ok":true,"ms":835,"cdp":"http://127.0.0.1:19401"},
   "chrome":{"ok":true,"ms":835,"cdp":"http://127.0.0.1:19402"},
   "camoufox":{"ok":true,"ms":35,"check":"import camoufox","python":"/tmp/cfx313/bin/python","version":"0.5.9"}}}}
```

### 2.8 线上实例（19555 / 19671）换码后复核

旧进程（pid 7665/7667，11:26 起）跑的是旧代码。`start-gateway.sh --stop` → `CAMOUFOX_PY=/tmp/cfx313/bin/python GATEWAY_TOKEN=... --daemon` 后：

```
$ bash scripts/start-gateway.sh --status
FARM_DB=/Users/xavier/Projects/ziniao-report/farm/state/farm.db
control: up pid=9253
gateway: up pid=9271

$ curl -s http://127.0.0.1:19671/v1/health
{"ok":true,"gateway":"up","control":"up","version":"1.1.0","contract_version":2,
 "hosts":[{"control":"http://127.0.0.1:19555","control_status":"up","running":0}],
 "engines":{"chromium":"up","linux150":"up","chrome":"up","camoufox":"unverified"}}

$ curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:19671/v1/sessions
401

$ curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:19671/v1/version
{"name":"ziniao-farm","version":"1.1.0","contract_version":2,
 "task_types":["goto","eval","click","type","shot","scan","extract","wait"],
 "engines":{"chromium":{"transport":"cdp","tasks":[...8 项]},"linux150":{"transport":"cdp","tasks":[...8 项]},
            "chrome":{"transport":"cdp","tasks":[...8 项]},"camoufox":{"transport":"worker","tasks":["goto","eval","shot","scan"]}},
 "attach_only":["linux150"]}

$ curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:19671/v1/version?require=99.0.0'
409

$ curl -s 'http://127.0.0.1:19671/v1/health?probe=1'
{"ok":true,"version":"1.1.0","engines":{"chromium":"up","linux150":"unverified","chrome":"up","camoufox":"up"},
 "probe":{"at":"2026-11-23T03:37:54.259Z","engines":{
   "chromium":{"ok":true,"ms":877,"cdp":"http://127.0.0.1:19400"},
   "chrome":{"ok":true,"ms":884,"cdp":"http://127.0.0.1:19400"},
   "camoufox":{"ok":true,"ms":40,"check":"import camoufox","python":"/tmp/cfx313/bin/python","version":"0.5.9"}}}}
```

## 3. fpgen 模型：这台机器必须绕一次 GitHub

`camoufox` 首次启动要装 fpgen 的 pinned 模型，`ensure_fpgen_model()` 走
`https://github.com/scrapfly/fingerprint-generator/releases/download/model-2/2026/model-release.zip`。

实测：`github.com` 连不通（curl 8 s 超时，`000`），进程卡在 `SYN_SENT → cdn-185-199-111-133.github.com`；
但 `api.github.com` 通（200 / 0.27 s）。走 API 资产口拿到同一份文件：

```
GET https://api.github.com/repos/scrapfly/fingerprint-generator/releases/tags/model-2%2F2026
→ asset 357981401  model-release.zip  1564571

GET https://api.github.com/repos/scrapfly/fingerprint-generator/releases/assets/357981401
    -H 'Accept: application/octet-stream'
→ http 200 bytes 1564571 time 46.148997s

shasum -a 256 /tmp/model-release.zip
6530b8322cdaa4ec042921c8d9a0369a0e6e0269ba636c01a7203e4a2f109936
expected（camoufox/fpgen-model.json 的 pin）
6530b8322cdaa4ec042921c8d9a0369a0e6e0269ba636c01a7203e4a2f109936
```

落盘按 pin 逐个成员校验 sha256 后写入 `site-packages/fpgen/data/`，mtime 设 2038-01-01、写 `.pinned-model` 戳，
即完成 `_install` + `_stamp` 等价动作，**没有降低完整性门槛**。

另：Python **3.15.2** 下 fpgen 解包报 `binascii.Error: Incomplete Base85 group`（`fpgen/unpacker.py:22`），
同模型换 **3.13.16** 正常。故 camoufox 的 `CAMOUFOX_PY` 本机指向 3.13 的 venv。

## 4. 缺口（单列）

1. **camoufox 仍是一次任务一个进程**：每次 `goto` 都重起 Firefox（本次实测首检 7.9 s、任务 3–6 s）。「一账号一个常驻 worker」的目标没做，吞吐上不去。
2. **`eval`/`shot` 形状未完全同形**：`goto` 已逐字对齐；`eval` 在 CDP 通道打印裸值/JSON，worker 返回 `{value}`；`scan` 在 CDP 返回平铺字段+`verdict`，worker 返回 `{probe}`。跨引擎写解析逻辑时要知道这条。
3. **worker 通道不探测出口 IP**：`check` 对 camoufox 恒报 `ip:null` + `ipErr`。`/v1/fingerprint/verify?with_ip=1` 对 camoufox 拿不到 IP 证据。
4. **health 的 camoufox 探针只到模块层**：`import camoufox` 成功即判 up，不启动浏览器，因此「up」不等于「能起 Firefox」。linux150 仍 `unverified`（需外部容器，本机 Docker 未运行）。
5. **`CAMOUFOX_PY` 必须显式配，且现在的 venv 在 `/tmp`**：默认 `python3` 没有 camoufox 包，不配会在第一次 camoufox 任务上失败、health 如实报 down。线上实例已用 `CAMOUFOX_PY=/tmp/cfx313/bin/python` 起，但 `/tmp/cfx313` 与 fpgen 模型都在临时目录，**重启机器即失效**；没写进 `start-gateway.sh`，也没做持久化。
6. **Python 3.15 的 fpgen 失败原因未定**，只是换了 3.13 绕过；没定位到是 stdlib `b85decode` 还是模型不兼容。
7. **profile 分区改了默认落点**：历史扁平目录（`profiles/default:m1-*`、`profiles/dy-parse`、`profiles/probe:health:*`）成为孤儿，未做迁移；本次只删了 `profiles/acc-smoke` 与本轮自建的 `amazon`/`ebay` 测试目录。
8. **版本契约只覆盖农场侧**：`/v1/version` 与 `contract.js` 已可用，但「平台子模式包安装时校验最低版本」要等 L3 打包，未开工。
9. **真实店铺账号仍是 0**（`hardening/FINDINGS.md` 的店铺数 0）。平台分区用 `ebay`/`amazon` 两个模拟平台验的分区与筛选，不是真实 eBay + Amazon 账号同时跑。
10. **`/v1/health?probe=1` 仍无鉴权**、`probe` 会写台账并建 profile 目录（增量 1 缺口 #1/#2 未变），本轮只把 camoufox 接进探针。
