# 未来规划（Roadmap v1）

日期：2026-11-24 (Asia/Shanghai)
依据：[产品化方案 v1](dsh-ecom-productization-plan.md) + 2026-11-24 缺口核查（核查命令见文末附录）
阶段 0 的 0.1–0.4 已完成，0.5 已删除 7 个孤儿 profile 目录，台账清理另行安排。阶段 1–4 各有前置条件。

## 0 一句话目标

**让第二个人在自己的机器上，从 clone 到「跑出一次能看的选品结论」，全程不需要项目主人在线。**
这条通了才谈得上卖；在那之前所有「加功能」都排在验证之后。

## 1 现在的真实位置

| 能力 | 状态 | 证据 |
|---|---|---|
| 装 | 通 | `bash distribution/verify.sh` → `PASS=63 FAIL=0 WARN=0` / `RESULT: READY`（2026-11-24 本机实测） |
| 跑 | 样例已跑通 | `bash distribution/flow-smoke.sh` → `PASS=8 FAIL=0 WARN=0` / `RESULT: READY`，四类产物通过内容校验（网关不可达时 L1、L2 各出一条 WARN，即 `WARN=2`） |
| 取数 | 缺外部条件 | 7 平台 API 全未接（manifest 写「未接入」）；无出口代理；`shopee` / `tiktokshop` 选择器标注「未验」 |
| 卖 | 缺产品本体 | L1 只是能力注册器：`brand.json` 的 `icon.present=false`、名称配色全占位；仓库内无授权校验代码 |

三条容易误判的事实：

1. `camoufox` 和 Chromium 均声明 8 项任务，真机验收已比对同一 `extract` 的结果与任务信封。
2. `distribution/l3/install.sh` 按平台 manifest 的最低农场版本判断。低版本拦截安装，网关不可达时提示 WARN 并继续检查 L2 前置。
3. **红线只有文档约束**：`farm/gateway/server.js` 与 `farm/contract.js` 里没有任何只读白名单/登录态拦截，「绝不用农场做登录态店铺操作」靠自觉。

工作量标记：**S** ≈ 半小时级，**M** ≈ 半天级，**L** ≈ 1–2 天级。这是判断，不是承诺。

---

## 2 阶段 0：从「装得起来」到「跑得通」

我独立可做，不需要用户、不需要外部账号。

| # | 事项 | 做什么 | 为什么现在做 | 估 |
|---|---|---|---|---|
| 0.1 | 业务流冒烟 | 补 4 个输入样例 CSV（列名照 `distribution/l2/skills/ecom-*/SKILL.md` 的「输入」段），新增 `distribution/flow-smoke.sh`：装进 mktemp 工作区 → 跑 4 个脚本 → 断言 4 类产物存在且非空 | 目前只证明「文件装对了」，没证明「流程跑得通」 | M |
| 0.2 | L3 版本闸 | `distribution/l3/install.sh` 增 `/v1/version` 比对，复用 L2 的 `ver_ge`；负例：把平台包 `requires["browser-farm"]` 抬到 `99.0.0` 必须 FAIL | 农场版本不够也照装，报错会晚到且难查 | S |
| 0.3 | Camoufox 任务对齐 | `farm/camoufox_worker.py` 先补 `extract` + `wait`（Playwright 原生能力），再补 `click` + `type`；同步 `farm/contract.js:35` 的 tasks 4 项 → 8 项 | 同一份契约下两个引擎只能跑一半任务，上层不敢用 camoufox | M×2 |
| 0.4 | 文档校准 | 产品化方案 §5 的 M1 状态（第 6 件未做）、§5.2 台账数字（写「10 行」，实际 5 行）；README 已指向本规划 | 规划与实际漂移，后来人会照着错的数看 | S |
| 0.5 | 清残留 | 已删除 `farm/profiles/` 下 7 个孤儿目录。保留 `default:e2e-smoke` 供 e2e 自检。 | `default:chief-probe`、`default:diag-shape`、`default:diag-dead` 这 3 个 stopped 测试账号留待另行安排。`farm/scripts/ledger-clean.sh` 的两道拒删闸当前都触发。一是 19671 或 19555 有服务监听，当前两端口均在监听。二是台账有 `running` 行或存活 PID，当前 `default:mkt-probe-amazon` 仍在运行。待运行会话结束、相关 PID 退出且服务停止后再清理。 | S |

验收：

```bash
bash distribution/verify.sh            # 期望 PASS 数不降、FAIL=0
bash distribution/flow-smoke.sh        # 4 类产物齐全
ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581 bash farm/scripts/acceptance.sh --with-browser
```

**闸门 G0**：以上三条全绿 → 才进入阶段 1。

## 3 阶段 1：第一次真人试装

只有这一步能把「别人能不能装通」从判断变成事实，项目主人和我都替不了。

| # | 事项 | 说明 |
|---|---|---|
| 1.1 | 找试装者 | 1–3 人，**至少 1 个 Windows**（macOS 一条路验不出跨平台问题） |
| 1.2 | 换令牌 | `GATEWAY_TOKEN` 现在 8 位，门槛 ≥32；`openssl rand -hex 32` 换掉，启动与 e2e 的 WARN 才会消 |
| 1.3 | 回收 5 条 | 按 [onboard-from-zero.md](onboard-from-zero.md) §11，要原文输出，不要转述 |
| 1.4 | 修卡点 | 按回收结果改文档/脚本，估 M（不确定，取决于卡点） |

验收：≥3 份回报（「5 条全过 + 系统版本」或等量卡点清单），卡点全部修完。

**闸门 G1**：试装人数与卡点清零 → 才可以对外说「别人可以照文档自助安装」。

## 4 阶段 2：真数据

依赖外部条件，按下列顺序推进（前一步不通不跳）：

| # | 事项 | 依赖 | 说明 |
|---|---|---|---|
| 2.1 | 代理接入 | 用户提供一条代理（`socks5h://` 优先，见 [proxy-runbook.md](proxy-runbook.md)） | 接上后跑 `farm/scripts/first-fetch.sh`，再逐平台验选择器；现有 amazon 记录是「出口日本、取到日元」，不算验过美国站 |
| 2.2 | 一条 T1 | SP-API 最优先（自家订单/库存/结算要对账） | 写 connector + 补降级链运行时：现在 `tier` 只写在 manifest 里，代码里没有任何调度按 tier 走 |
| 2.3 | T2（可选） | 卖家精灵/Sorftime 账号 | 不接也能跑，只影响速度与稳定性 |

验收：同一账号 `farm_task extract` 拿到 `{title, price}` 且 `status != blocked`；真实订单进 `orders.csv` 后能跑出运营日报。

**闸门 G2**：代理 + 至少 1 条 T1 打通 → 才可以对外说「能取真实平台数据」。

## 5 阶段 3：能卖

以下每一项都以「商业化形态已定」为前提，顺序不能颠倒：

| # | 事项 | 说明 |
|---|---|---|
| 3.1 | L1 fork 品牌化 | 定稿 `distribution/l1/branding/brand.json` + 图标，改动落在 fork 仓 `ethanqing1-arch/deepseek-harness`。**现在该仓是纯镜像**（HEAD = 上游 release `4b399c39a6`，与远端 `0 0`、工作区干净），此刻改动成本为 0；一旦开始改，每个上游版本都要 rebase |
| 3.2 | 授权校验 | 离线 licence + 机器码绑定；先定防拷贝强度，再写代码。仓库内目前没有任何实现 |
| 3.3 | 三件插件入 L1 bundle | `retrace` / `rollback-withdraw` 现在都没装；`prompt-enhancer` 只在本机装了 1.2.2，L1 包没有 bundle 目录承载它们 |
| 3.4 | amazon 23 skill 授权归属 | 法律/采购问题，不是技术问题；未定就不能合法对外分发 |
| 3.5 | 安装包 | dmg/zip 打包 + 首次启动引导 |

验收：干净机器用安装包从 0 到跑通选品，全程不需要命令行。

**闸门 G3**：商业形态 + 授权归属都定了 → 才可以对外售卖。

## 6 阶段 4：长期（按需，不排期）

- 其余 6 平台专项 skill：现在 `distribution/l3/platforms/ebay/` 只有 manifest + overrides + 空 `skills/`
- 常驻 worker：设计已有（`docs/camoufox-persistent-worker-design.md`，36 行），等任务量真的需要再做
- DSH 上游跟进：现在每个 release 评估一次就够；改过品牌后变成必做项

---

## 7 为什么这么排

1. **先验证再扩功能**：现在最贵的不是缺功能，是没人证明这条链能跑通。
2. **Camoufox 排在 L1 前面**：它是取数能力的第二条腿，且不依赖外部账号，是阶段 0 里唯一能实质提升能力的项。
3. **L1 放最后**：品牌化 + 授权一旦做，就跟上游版本绑死，成本从 0 变成长期；商业形态没定就做，很可能白做。

## 8 不做什么（免得跑偏）

- 不做国内电商平台：清单里的国内包费率口径不通用，跨境要按平台佣金 + 履约重写
- 不装 `dsh-memory-plugin`：`dsh: {}` 为空不是 bundle，且会和 DS Bot 自带记忆打架
- 不把农场用于登录态店铺操作：这是红线，且代码层没有拦截，只能靠流程与人工审核
- 代理/授权到位前，不做平台选择器的「优化」类工作 —— 没有真数据的优化都是猜

## 9 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| 代理与 API 授权时间不可控 | 阶段 2 一直挂着 | 阶段 0/1 不依赖它们，先做 |
| 找不到试装的人 | 阶段 1 一直挂着 | 把门槛降到「一台电脑 + 30 分钟」，并提供回报模板 |
| 商业形态不定 | L1 停在占位，无法收费 | 阶段 1 收完反馈再定，那时信息最全 |
| 红线无代码拦截 | 卖出去可能被误用，封店风险由客户承担 | 阶段 3 之前补只读白名单或在协议里写死 |

## 10 附录：本规划的核查命令

```bash
# 装链
bash distribution/verify.sh                                   # PASS=63 FAIL=0 WARN=0 / READY

# Camoufox 任务契约
grep -n "camoufox:" farm/contract.js                          # tasks: TASK_TYPES.slice()

# L3 农场版本闸（负例随 verify.sh 运行）
grep -n "requires.browser-farm" distribution/l3/install.sh

# 业务脚本输入
bash distribution/flow-smoke.sh                               # PASS=8 FAIL=0 WARN=0 / READY（19671 在跑；网关离线时 WARN=2）
grep -n "os.path.join(BASE, \"data\"" distribution/l2/workspace/scripts/*.py

# 红线无拦截
grep -rn "readonly\|E_FORBIDDEN\|allowlist\|白名单" farm/gateway/server.js farm/contract.js   # 无输出

# L1 占位与 fork 状态
grep -n "present" distribution/l1/branding/brand.json         # icon.present=false
cd ~/Projects/deepseek-harness && git log -1 --format='%h %s' && git rev-list --left-right --count origin/master...HEAD

# 外部依赖现状
python3 -V                                                    # 系统 python 3.9；camoufox 走 ~/.dsh/venvs/camoufox
echo ${#DSH_SECRET_GATEWAY_TOKEN}                             # 8（门槛 ≥32）
```
