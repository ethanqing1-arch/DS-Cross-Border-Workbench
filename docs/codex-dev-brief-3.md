# Codex 交接单 3：阶段 0（把「装得起来」变成「跑得通」）

依据 [`roadmap.md`](roadmap.md) §2 阶段 0。四项：业务流冒烟、L3 版本闸、Camoufox 任务对齐、文档校准。
第 5 项（清残留）**不在本单范围** —— 要动台账与 profiles，须用户批准后才做。

## 约束（必读）

**不要碰正在跑的东西。** 线上服务此刻在跑，且有别人的会话：

```
gateway  pid 99947（19671）   control  pid 99944（19555）
台账 accounts 里 default:mkt-probe-amazon 状态 running —— 不是我们的，别停
```

- **不许** `start-gateway.sh --stop/--daemon`、不许 kill 上述进程、不许重启网关。
- 要跑 `acceptance.sh` 必须用独立端口：`ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581`（脚本第 10–11 行支持覆盖），它会用自己的临时 `FARM_DB`（第 74 行），不会写 `farm/state/farm.db`。
- **不许**删 `farm/profiles/` 下任何目录，**不许**动 `farm/state/farm.db`。
- **不许**碰 `~/.ds-bot/skills/`、DS Bot 应用状态、launchd、系统设置。
- **不许**碰 `distribution/l3/platforms/amazon/`（外部资产，授权待定）与 `evidence/`。
- 令牌只从环境变量读，**绝不写进文件、argv、日志**。
- `distribution/l2/skills/` 与 `distribution/l2/bundle/skills/` 必须逐文件一致（`diff -qr` 必须无输出）。
- 拿不准就停，把卡点写清楚；**不要伪造 PASS 数字**，网关不可达导致的 WARN 照实留。

改完自己 commit，只提交你改的文件。`docs/roadmap.md` 与本交接单已由我先提交，别把它们混进你的 commit。

---

## T1 业务流冒烟（roadmap 0.1）

**现状**：`distribution/l2/workspace/data/` 只有 `faq.json`；四个业务脚本分别写死读取
`data/candidates.csv`、`data/orders.csv`、`data/products.csv`、`data/messages.csv`，缺文件直接 `sys.exit`。
所以现在只证明了「文件装对了」，没证明「流程跑得通」。

**要做**：

1. 新增 4 个样例（≤10 行、UTF-8、中文表头，放在 `distribution/l2/workspace/data/`，**用 `.sample.csv` 后缀**）：
   - `candidates.sample.csv`：列见 `distribution/l2/skills/ecom-selection/SKILL.md` 第 58 行；至少 1 行触发红线（毛利率 < 25% 或贡献利润率 < 8%）
   - `orders.sample.csv`：列见 `distribution/l2/skills/ecom-ops/SKILL.md` 第 60 行；至少 1 条退款
   - `products.sample.csv`：列见 `distribution/l2/skills/ecom-listing/SKILL.md` 第 54 行
   - `messages.sample.csv`：列见 `distribution/l2/skills/ecom-cs/SKILL.md` 第 63 行；至少 1 条会转人工的高风险消息
   - **列名以脚本实际读取的 key 为准**（`score_products.py` / `gen_listing.py` / `ops_report.py` / `cs_router.py`），跑一遍缺哪个补哪个，不要只照文档抄。
2. 新增 `distribution/flow-smoke.sh`：
   - `mktemp` 空工作区 → 装 L1 + L2（复用两个 install.sh）→ 把 4 个 `*.sample.csv` 复制成 `data/<name>.csv` → 用 `python3` 依次跑 4 个脚本
   - 断言 4 类产物存在且非空：`out/选品打分.csv`、`out/上架包/`（至少 1 个文件）、`out/运营日报.md`、`out/客服处理.csv`
   - 输出格式与其它脚本统一：`== 汇总: PASS=n FAIL=n WARN=n ==` + `RESULT: READY|FAILED`，退出码 0/1
   - 不写仓库内任何文件；不留临时目录
3. 更新 4 个 SKILL.md 的「输入」段（**skills/ 与 bundle/skills/ 两份镜像都要改**）：
   现在写「`data/xxx.csv` 需自行导出」→ 补一句「随包带 `data/xxx.sample.csv` 样例，真数据覆盖同名 `xxx.csv`」。
4. `distribution/verify.sh` 的 L2 文件数是动态计算的（第 124–129 行），加文件不会破；但要跑一遍确认 PASS 数只增不减。

**验收**：

```bash
bash distribution/flow-smoke.sh        # RESULT: READY，4 类产物齐全
bash distribution/verify.sh            # FAIL=0 WARN=0，PASS 数 ≥ 62
```

---

## T2 L3 版本闸（roadmap 0.2）

**现状**：`distribution/l3/install.sh` 只校验平台 manifest 的 schema（第 71–113 行那段 `node -e`），
**不比对农场版本**；`requires["browser-farm"]` 只是声明。L2 有闸（`distribution/l2/install.sh` 第 37 行 `ver_ge`、第 53–85 行 `check_gateway`），L3 没有。

**要做**：

1. 在 `distribution/l3/install.sh` 的 schema 校验之后、L2 前置检查之前，加「农场版本闸」：
   - 读本平台 manifest 的 `requires["browser-farm"]`
   - 请求 `${GATEWAY_URL}/v1/version`；有 `GATEWAY_TOKEN` 带 Bearer，没有则退免鉴权的 `/v1/health`（它同样带 `version`）
   - 语义照 L2：**网关不可达 / 非 200 / 无 version 字段 → WARN 并继续**；**版本低于要求 → FAIL，且不写任何文件、退出码非 0**
   - `ver_ge` 函数从 L2 复制一份到 L3（不要跨脚本 `source`）
2. 在 `distribution/verify.sh` 加一条负例：把某个平台包整个复制到 `mktemp`，把 `requires["browser-farm"]` 改成 `"99.0.0"`，跑 install 期望 FAIL 且目标目录无写入；**原包一个字节都不许动**。
3. 注意别把 verify 变成依赖网关的测试：网关在跑时这条要 PASS，网关不在时只 WARN。

**验收**：

```bash
bash distribution/verify.sh            # 新增的负例 PASS，整体 READY
GATEWAY_URL=http://127.0.0.1:1 bash distribution/l3/install.sh amazon "$(mktemp -d)"   # WARN 不 FAIL
```

---

## T3 Camoufox 任务对齐（roadmap 0.3）

**现状**：`farm/contract.js:35` 里 camoufox 只有 4 项任务：

```js
camoufox: { transport: 'worker', tasks: ['goto', 'eval', 'shot', 'scan'] },
```

`farm/camoufox_worker.py` 第 129–160 行的任务分发也只实现这 4 个。
网关侧 `TASK_REGISTRY` 已有 `click/type/extract/wait`，只是 camoufox 通道拿不到。

**要做**：

1. `farm/camoufox_worker.py` 补 4 个任务，**输出形状必须与 CDP 通道逐字同形**（对照 `farm/driver.js`）：
   - `extract`（driver.js 第 214–250 行）：params `selector_map` / `url` / `timeout_ms`；输出 `{ok, url, fields, missing}`；字段缺失**不算硬失败**（`ok:false` 但 exit 0）；导航超时输出 `{ok:false, url, readyState, error:'navigation timeout'}` 且 exit 1
   - `wait`（driver.js 第 250–266 行）：params `selector` / `state`(`present|absent`) / `timeout_ms`；输出 `{ok, selector, state, found, waited_ms}`；未满足 exit 1
   - `click`：params `x` / `y`；输出形状对照 driver.js 的 click 返回
   - `type`：params `text`，`mode==='keys'` 时逐键输入（CDP 语义），否则整段输入；输出形状对照 driver.js
2. `farm/contract.js:35` 的 tasks 改成 8 项（`TASK_TYPES.slice()` 即可，别再手写子集）。
3. `acceptance.sh` 里与 camoufox 相关的断言若写死了 4 项，同步改；再加一条：同一 `extract` 在 camoufox 与 chromium 上**键集与信封一致**。

**验收**：

```bash
ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581 bash farm/scripts/acceptance.sh --with-browser
# 期望 PASS=n FAIL=0 WARN=0 / READY，n 不低于改前
grep -n "camoufox:" farm/contract.js    # tasks 为 8 项
```

---

## T4 文档校准（roadmap 0.4）

1. `docs/dsh-ecom-productization-plan.md`：
   - §5 表格 M1 那行：现在整体标 ✅，但第 6 件（Camoufox 归一）当时没做；按实际状态写清（若 T3 做完就写已归一，并注明 commit）
   - §5.2 表「台账测试账号」写「10 行」→ 改成你实际数出来的（`sqlite3 farm/state/farm.db "select count(*) from accounts;"`，**只读**）
2. 所有 PASS 数只写**你自己跑出来的**。需要回填的位置：
   - `README.md` 第 40–45 行验收基线表
   - `docs/onboard-from-zero.md` 第 94 行与第 250 行（现在写的 `PASS=61` 已过期）
   - `docs/external-setup.md` 第 245–247 行
   - `docs/roadmap.md` 第 132 行附近
3. 不许为了对齐数字去改断言；断言是准绳，数字跟着断言走。

---

## 回报格式

每条给 **命令原文输出**（含退出码）与卡点，不要转述：

```
T1: flow-smoke → <原文>；verify → <末两行>；PASS 数 62 → ?
T2: 负例 → <原文>；网关不可达 → <原文>
T3: contract.js tasks → <原文>；acceptance 汇总 → <原文>
T4: 改了哪几处数字 → <文件:行>，每个数字对应的命令
```

卡住就停在原地写清：哪一行、什么错、试过什么。
