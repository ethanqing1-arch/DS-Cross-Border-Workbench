# Codex 交接单 6：补两个技术缺口（wait 的 visible/hidden、e2e 锁分支）

## 背景（我今晚实测，不是推测）

**缺口 1：`wait` 的 `visible` / `hidden` 两个引擎都不支持。** 我在隔离实例（独立端口 19655/19771、临时 FARM_DB、不动线上服务）上各建一个 chromium 与 camoufox 会话，提交三种 wait，返回原文：

```text
wait chromium {"selector":"body","state":"visible","timeout_ms":1500} => {"status":200,"result":{"ok":false,"status":"failed","error":{"code":"E_INTERNAL","message":"ERR --state must be present|absent"}}}
wait chromium {"selector":"body","state":"bogus","timeout_ms":500}   => {"status":200,"result":{"ok":false,"status":"failed","error":{"code":"E_INTERNAL","message":"ERR --state must be present|absent"}}}
wait camoufox {"selector":"body","state":"visible","timeout_ms":1500} => {"status":200,"result":{"ok":false,"status":"failed","error":{"code":"E_INTERNAL","message":"--state must be present|absent"}}}
wait camoufox {"selector":"body","state":"bogus","timeout_ms":500}   => {"status":200,"result":{"ok":false,"status":"failed","error":{"code":"E_INTERNAL","message":"--state must be present|absent"}}}
```

两边都拒绝，但 message 不一致（chromium 多一个 `ERR ` 前缀），而且真实网页最常用的「元素存在但不可见」现在没法等。

**缺口 2：e2e 锁的 `flock` 分支在本机无从验证**（macOS 没有 `flock` 命令，实际永远走 perl 分支）。两个分支只留一个实测过的。

## 约束（必读）

- 不要停/重启 gateway（pid `31679` @19671）或 control（pid `99944` @19555），不要 kill 浏览器（Chromium `23934`）。
- 不要动 `farm/state/farm.db`、台账任何一行、`farm/profiles/`（本轮刚清过）、`~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- acceptance 必须用独立端口：`ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581`，它自带临时 `FARM_DB`。
- 令牌只从环境变量读，不进 argv、不落文件、不打印。
- **不要改 `farm/gateway/server.js`**；如果发现不改它做不成，停下写清原因，不要自己重启服务。
- 只改：`farm/driver.js`、`farm/camoufox_worker.py`、`farm/scripts/acceptance.sh`、`distribution/e2e-smoke.sh`，以及回填实测数字的文档。
- 拿不准就停，写清卡点；**不许伪造 PASS 数字**。
- 改完自己 commit，只提交你改的文件。

---

## T1 两个引擎都支持 `visible` / `hidden`，语义逐字对齐

**现状代码位置**：

- chromium：`farm/driver.js:250-266` 的 `wait` 分支，只接受 `present|absent`；
- camoufox：`farm/camoufox_worker.py:216-221` 只接受 `present|absent`，`wait_for_selector()` 在 `:121-137`；
- 网关把参数原样传给引擎：`farm/gateway/server.js:52`。

**要的语义**（两个引擎必须用同一段 JS 判定，保证同形）：

```js
// SEL 替换成选择器字面量
(() => {
  const el = document.querySelector(SEL);
  if (!el) return { exists: false, visible: false };
  const r = el.getBoundingClientRect();
  const cs = getComputedStyle(el);
  return { exists: true, visible: r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' };
})()
```

> 口径按 Playwright：`visibility:hidden` 与空盒算不可见；`opacity:0` **算可见**（别自己加规则，加了就和 Playwright 用户预期不一致）。

四个 state 的判定：

| state | 满足条件（`ok:true`） |
|---|---|
| `present` | `exists` |
| `absent` | `!exists` |
| `visible` | `exists && visible` |
| `hidden` | `!(exists && visible)`（元素不存在也算 hidden，与 Playwright 的 hidden 一致） |

**result 形状不许变**，仍是 `{ok, selector, state, found, waited_ms}`：
- `found` 继续表示「元素是否存在」（`exists`），不要塞别的含义；
- `waited_ms` 两边天然不同，不参与比对；
- 轮询仍 200ms 一次，`timeout_ms` 默认 30000，未满足 `ok:false` 且引擎退出码 1（现有行为不动）。

**非法 state**（如 `bogus`）：两个引擎都返回 `error.code === 'E_INTERNAL'`，且 **`error.message` 完全一致**，都写成 `--state must be present|absent|visible|hidden`。

坑：chromium 侧现在的 `ERR ` 前缀来自 `driver.js` 末尾的兜底 `console.error('ERR', e.message)`（`farm/driver.js:311` 附近），control 把 stderr 原文当 message（`farm/control.js:77`）。所以这一处要自己打干净的一行，别让 `ERR ` 或 JSON 串进 message。

**acceptance 新增跨引擎比对**（`farm/scripts/acceptance.sh` 里 `checkWaitParity()` 之后新增 `checkWaitStates()`，注册进末尾 `for (const [name, check] of [...])`）：

对两个引擎各提交 5 条 wait，断言任务信封与 result 键集一致，且除 `waited_ms` 外逐键相等：

```js
{ selector: 'body',    state: 'visible', timeout_ms: 1500 }  // ok:true,  found:true
{ selector: '#nope',   state: 'visible', timeout_ms: 800  }  // ok:false, found:false
{ selector: '#nope',   state: 'hidden',  timeout_ms: 800  }  // ok:true,  found:false
{ selector: 'body',    state: 'hidden',  timeout_ms: 800  }  // ok:false, found:false
{ selector: 'body',    state: 'bogus'    }                   // 两边 failed，error.code/message 一致
```

新增一条 bash 断言，成功时打印 `Camoufox 与 chromium 的 wait 四种 state 同形`。

**验收**：

```bash
ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581 bash farm/scripts/acceptance.sh --with-browser
# 期望：PASS=72 FAIL=0 WARN=0 / READY（71 + 新增 1 条）
```

注意：worker 一个任务起一次浏览器，只能在初始空页上测 —— 不要试图 goto 再 wait（页面不共享）。上面 5 条都用空页即可成立。

---

## T2 e2e 锁只留 perl 一个分支

**现状**：`distribution/e2e-smoke.sh` 第 75 行附近先 `command -v flock` 存在就用 `flock -n -E 3 9`，否则用 perl。本机没有 `flock`，所以 `flock` 那支从未执行过。

**要改**：删掉 `flock` 分支，统一走 perl 实现（Linux 上也自带 perl，`Fcntl` 的 `flock` 是 POSIX 语义）。锁的语义保持：拿不到锁 → `SKIP` + `RESULT: SKIPPED` + exit 3。

**验收（三条都要贴原文）**：

```bash
# 1) 单跑
bash distribution/e2e-smoke.sh          # PASS=34 FAIL=0 WARN=1 / READY / exit=0

# 2) 两个 e2e 并发：第二个必须 SKIP exit=3，第一个 READY
bash distribution/e2e-smoke.sh > /tmp/e2e-a.log 2>&1 &
sleep 2
bash distribution/e2e-smoke.sh; echo "exit=$?"   # SKIP + RESULT: SKIPPED + 3
wait

# 3) acceptance 在跑时跑 e2e：必须 SKIP 并报出 acceptance 的 pid
```

---

## T3 文档回填（只写你跑出来的数）

- `README.md` 验收表：`acceptance.sh` 那行 PASS 数（71 → 你实测的），`e2e-smoke.sh` 那行保持 34/0/1；
- `docs/external-setup.md:245` 附近的同组基线；
- `docs/m1-increment1.md` 的 wait 段落（`:15` 与 `:24` 附近的示例）：state 取值补全为 `present|absent|visible|hidden`，并写清 `visible`/`hidden` 的判定口径；
- `docs/roadmap.md` 里提到 wait 只测了 absent 的地方（如有）。

不要改历史交接单（`docs/codex-dev-brief-3.md` 那类），那是当时记录。

---

## 回报格式

```
T1：acceptance 末尾原文；新增断言那行原文；5 条 wait 在两个引擎上的实测输出（贴 JSON）
T2：三种场景的 exit code 与 SKIP/READY 原文
T3：改了哪几处（文件:行），每个数字对应哪条命令
```

卡住就停在原地写清：哪一行、什么错、试过什么。
