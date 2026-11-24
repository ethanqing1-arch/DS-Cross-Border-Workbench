# Codex 交接单 4：把两条自检从「跑过了」升级为「算得对」

上一轮阶段 0 已完成并上线（`42bcfac`）。两处自检强度不够，需要补：

- `distribution/flow-smoke.sh` 现在只断言产物**存在且非空**，脚本跑通但算错也会判绿。
- `farm/scripts/acceptance.sh` 只比对了 `extract` 的跨引擎契约，worker 新加的 `wait` 分支没有回归保护。

## 约束（必读）

- **不要碰正在跑的服务**：gateway pid 见 `farm/state/gateway.pid`，control 也在跑；台账里有 `default:mkt-probe-amazon` 状态 running（别人的会话）。
- 跑 acceptance 必须用独立端口：`ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581`（它自带临时 `FARM_DB`）。
- 不要动 `farm/state/farm.db`、`farm/profiles/`、`~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- 令牌只从环境变量读，不进 argv、不落文件、不打印。
- 只改：`distribution/flow-smoke.sh`、`farm/scripts/acceptance.sh`，以及回填实测数字的文档。
- 拿不准就停，写清卡点；**不许伪造 PASS 数字**，网关不可达导致的 WARN 照实留。
- 改完自己 commit，只提交你改的文件。

---

## T1 flow-smoke 加内容断言

**现状**：`run_flow()` 只判断产物文件存在且非空（`distribution/flow-smoke.sh` 第 45–62 行附近）。

**实测产物形状**（我已跑过，你按这个写断言）：

`out/选品打分.csv` 表头：

```
商品名,品类,预估售价,表面毛利,贡献利润,贡献利润率,分层,月搜索量,在售竞品数,供需比,退货率,总分,决策,诊断,红线,差异化点
```

两行样例的结论分别是 `决策=上架测试`（红线列空）与 `决策=放弃`（红线列是「毛利率<25%不进付费测款/…」）。
`out/上架包/` 有 2 份 `.md`；`out/平台导入表.csv` 非空；`out/运营日报.md` 正文含 `GMV`、`退款率`、`贡献利润`；
`out/客服处理.csv` 有 `是否转人工` 列，样例里 `是` 与 `否` 各一条。

**要加的四条断言**（每条一个 PASS，用 bash 里现有的 `ok`/`bad`）：

1. `选品打分.csv`：`决策` 列同时出现 `上架测试` 与 `放弃`；`放弃` 那行 `红线` 非空。
2. `上架包`：≥2 份 `.md`，且 `out/平台导入表.csv` 非空。
3. `运营日报.md`：正文同时含 `GMV`、`退款率`、`贡献利润` 三个口径词。
4. `客服处理.csv`：`是否转人工` 列同时出现 `是` 与 `否`（证明风险分流真的生效）。

要求：CSV 用 `python3` + `csv.DictReader(..., encoding='utf-8-sig')` 读（首列有 BOM，直接 grep 会踩坑）；断言失败时打印实际值，别只说 FAIL。

**验收**：

```bash
bash distribution/flow-smoke.sh     # 期望 PASS 由 4 涨到 8，RESULT: READY
```

---

## T2 acceptance 补 wait 的跨引擎比对

**现状**：`farm/scripts/acceptance.sh` 里 node 段（约第 260–305 行）有 `checkExtractParity()`，只测了 `extract`。
worker 现在也支持 `wait`（`farm/camoufox_worker.py` 的 `wait_for_selector`），没有回归断言。

**要加**：同文件 node 段新增 `checkWaitParity()`，并注册进末尾的 `for (const [name, check] of [...])` 数组。

**必须注意的坑**：worker 是「一次任务一个进程」，`goto` 与 `wait` 分成两次任务时页面不共享 —— **不能**先 goto 再 wait。
所以用空页上「等一个不存在元素消失」这个用例，两引擎都应立刻满足：

```js
const params = { selector: '#absent-on-blank-page', state: 'absent', timeout_ms: 1500 };
const a = await submit(cdp, { type: 'wait', params });
const b = await submit(worker, { type: 'wait', params });
```

断言：任务信封键集一致、`result` 键集一致、`ok`/`found`/`state`/`selector` 逐项相等（`waited_ms` 两边必然不同，不要整体 `deepEqual`）。

**验收**：加一条 bash 断言（照现有两条的写法），成功时打印 `Camoufox 与 chromium 的 wait 结果同形`。

```bash
ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581 bash farm/scripts/acceptance.sh --with-browser
# 期望 PASS 由 70 涨到 71，FAIL=0 WARN=0 / READY
```

如果 worker 启浏览器 + wait 1500ms 逼近 `submit()` 的 15 秒轮询上限，**只调测试里的等待上限**，不要动生产任务超时。

---

## T3 回填实测数字

改完必须把**你自己跑出来**的数字回填，位置：

- `README.md` 验收基线表：`flow-smoke.sh` 的 PASS 数、`acceptance.sh` 的 PASS 数
- `docs/external-setup.md` 第 245 行附近同一张快照
- `docs/roadmap.md` 里引用这两个数字的地方（如有）

只写跑出来的数，跑出 WARN 就写 WARN。

---

## 回报格式

```
T1: flow-smoke → <末尾原文，含 PASS/FAIL 与 RESULT>；exit=?
T2: acceptance → <末尾原文>；新断言那行原文
T3: 改了哪几处数字 → <文件:行>，每个数字对应哪条命令
```

卡住就停在原地写清：哪一行、什么错、试过什么。
