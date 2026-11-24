# Codex 交接单 5：e2e 并发假红改成显式 SKIP + 清孤儿 profile 目录

## 背景（都是我跑出来的现状，2026-11-24 15:05 前后）

| 命令 | 实测结果 |
|---|---|
| `ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581 bash farm/scripts/acceptance.sh --with-browser` | `PASS=71 FAIL=0 WARN=0` / `READY`，exit=0 |
| `bash distribution/verify.sh` | `PASS=63 FAIL=0 WARN=0` / `READY` |
| `bash distribution/flow-smoke.sh`（PATH 含 node） | `PASS=8 FAIL=0 WARN=0` / `READY` |
| `bash distribution/e2e-smoke.sh`（单跑） | `PASS=34 FAIL=0 WARN=1` / `READY` |

服务在跑，别碰：gateway pid `31679` @ `127.0.0.1:19671`，control pid `99944` @ `127.0.0.1:19555`；台账里 `default:mkt-probe-amazon` 是 running，Chromium pid `23934`。

## 约束（必读）

- 不要停/重启 gateway 或 control，不要 kill 任何浏览器进程。
- 不要写 `farm/state/farm.db`、不要动台账任何一行（本单 T3 明确「不做」）。
- 除 T2 列出的 7 个目录，不要删 `farm/profiles/` 下任何东西。
- 不要动 `~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- 令牌只从环境变量读，不进 argv、不落文件、不打印。
- 只改：`distribution/e2e-smoke.sh`、`README.md`、`docs/roadmap.md`（需要时）。
- 拿不准就停，写清卡点；**不许伪造 PASS 数字**，跑出 WARN 照实写。
- 改完自己 commit，只提交你改的文件。

---

## T1 e2e 并发时不许报假红（核心）

**故障原文**（我在 e2e 与 acceptance、`test-proxy-bridge.sh` 并发时实测）：

```text
  FAIL 本地 fixture 正常页（RC=1）status=error code=E_TIMEOUT
  FAIL --out 产物异常：jsonl_lines=0 status=error exit=1 item_count=0
== 汇总: PASS=32 FAIL=2 WARN=1 ==
RESULT: NOT_READY
```

**定位**：两处 FAIL 都在第 5 段（`distribution/e2e-smoke.sh:402` 起）。`probe_run()` 用 `--account e2e-smoke` 走**共享网关/控制面**驱动浏览器；`distribution/connectors/farm-probe.js` 默认 `--timeout-ms 45000`，任务 `wait_ms` 是 60000，并发抢浏览器时先超时。

**要的行为**（不是「重试到过」，是「诚实地说没跑」）：

1. 在网关硬闸之后、第 1 段边界快照之前（`distribution/e2e-smoke.sh` 第 86 行之前）加前置探测：
   - 用 `flock -n` 拿 `e2e-smoke.sh` 自己的锁（两个 e2e 同时跑时后来的直接让位）；
   - 用 `ps -Ao pid=,command=` 扫是否已有别的**浏览器自检**在跑：`acceptance.sh`、`test-proxy-bridge.sh`、`proxy-selftest.sh`、另一个 `e2e-smoke.sh`。排除 `$$` 与 `$PPID`，排除自己这行命令。
2. 命中任一 → 只打印一行 `SKIP 检测到并发的浏览器自检（pid ...），e2e 必须单跑` 和 `RESULT: SKIPPED`，**exit 3**，然后退出。此时不得创建任何会话、不得写工作区、不得改动真工作区。
3. 单跑路径的行为与数字保持不变：仍是 `PASS=34 FAIL=0 WARN=1` / `READY` / exit 0。

**禁止**：不许把断言删掉或放宽来「变绿」；不许把 FAIL 改成 PASS；不许静默跳过（必须打出 SKIP 与 pids）。

**验收（两条都必须贴原文）**：

```bash
# 1) 单跑
bash distribution/e2e-smoke.sh; echo "exit=$?"
# 期望：PASS=34 FAIL=0 WARN=1 / RESULT: READY / exit=0

# 2) 并发
bash distribution/e2e-smoke.sh > /tmp/e2e-a.log 2>&1 &
sleep 1
bash distribution/e2e-smoke.sh > /tmp/e2e-b.log 2>&1; echo "exit=$?"
grep -E 'SKIP|RESULT|PASS=|FAIL=' /tmp/e2e-a.log /tmp/e2e-b.log
# 期望：第二条 exit=3 且打出 SKIP + RESULT: SKIPPED；第一条 READY；两份日志 FAIL=0
```

---

## T2 删 7 个孤儿 profile 目录

这 7 个目录我都查过台账：**0 行引用**，是早期探针留下的孤儿。

```text
farm/profiles/probe:health:chrome
farm/profiles/probe:health:chromium
farm/profiles/default:m1-dbg
farm/profiles/default:m1-dbg2
farm/profiles/default:m1-extract
farm/profiles/default:m1-extract2
farm/profiles/default:verify-01
```

**删前每一条都要自己再确认**（不要信我写的）：

1. `sqlite3 farm/state/farm.db "select count(*) from accounts where profile like '%/<目录名>';"` 必须是 `0`；
2. `lsof +D "<绝对路径>"` 必须没有输出（有输出就跳过该目录并报告）；
3. 只 `rm -rf` 这 7 个绝对路径，逐个删、删完 `ls` 复核。

**不要动**：`farm/profiles/{amazon,1688,e2e,_unsorted,cf,probe,dy-parse}`，也不要动台账里那 5 行的 profile 路径（`amazon/default:mkt-probe-amazon`、`1688/default:chief-probe`、`e2e/default:e2e-smoke`、`_unsorted/default:diag-*`）。

**验收**：`df`/`du -sh farm/profiles` 前后对比；`ls farm/profiles` 原文；`bash distribution/verify.sh` 仍 `PASS=63 FAIL=0 WARN=0`。

---

## T3 台账清理：本单**不做**，只把这个事实写进文档

`farm/scripts/ledger-clean.sh` 有两道拒删闸，现在都关着：

- 闸 1：19671 或 19555 有 LISTEN → 拒；
- 闸 2：有 `status='running'` 的行或 pid 还活着 → 拒（现在 `default:mkt-probe-amazon` 就是 running）。

所以台账 3 个 stopped 测试账号（`default:chief-probe`、`default:diag-shape`、`default:diag-dead`）**这次清不了**，要等 running 会话结束、服务停掉之后。

你要做的只有：在 `docs/roadmap.md` 的 0.5 行（第 41 行）把状态改准确 —— 已删 7 个孤儿目录；台账 3 个测试账号因上面两道闸仍需另行安排；`default:e2e-smoke` 是 e2e 自检账号，**保留**（原文写的「4 个」不对）。同时把第 5 行的「清残留仍待授权」改成当前真实状态。

**禁止**：不要停服务、不要 kill 23934、不要 `--apply`、不要手写 SQL 删行。

---

## T4 文档回填

- `README.md:44`：e2e 那行补上 SKIP 语义（并发时 `exit 3` / `RESULT: SKIPPED`，不算 FAIL）。
- `README.md:49`：原来写「必须单跑…报假红（实测 32/2）」，改成「必须单跑；并发时前置探测会 SKIP（exit 3），不再报假红」。
- `docs/roadmap.md:5`、`:41`：按 T3 的真实状态改。
- 所有数字以你自己跑出来的为准。

---

## 回报格式

```
T1 单跑：<末尾 4 行原文>；exit=?
T1 并发：<第二条末尾原文 + SKIP 行原文>；exit=?
T2：删除清单（逐个成功/跳过原因）+ du 前后 + verify 末尾原文
T3/T4：改了哪几处（文件:行），每个数字对应哪条命令
```

卡住就停在原地写清：哪一行、什么错、试过什么。
