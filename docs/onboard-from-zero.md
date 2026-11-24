# 从零到能用：给别人装一套数字员工

读者：拿到这个仓库、想在自己机器上跑起同样 11 个跨境电商数字员工的人。

本文只讲「一台干净机器 → 11 个员工能干活」。农场引擎怎么装、装不上看哪条，见
[`external-setup.md`](external-setup.md)；取数口径见 [`data-fetch-runbook.md`](data-fetch-runbook.md)；
代理排查见 [`proxy-runbook.md`](proxy-runbook.md)。

---

## 0. 先说清楚你拿到的是什么

| 你会得到 | 你不会得到 |
|---|---|
| 11 个 bot 的定义（名字 / 角色 / 指令原文） | 它们的**长期记忆** —— 每个 bot 的 memory 是自己的，换机器从零开始 |
| 5 个群的成员、admin 与 notice | 任何对话历史 |
| 工作区骨架 + 6 个业务模板 + `CHIEF-INIT.md` | 任何 secret、令牌、API key |
| L2 的 6 个跨平台 skill + Amazon 的 23 个专项 skill、其余 6 平台的框架 | 平台 API 授权（7 个平台一个都没接） |
| 7 个 `farm_*` 浏览器工具 | 出口代理（没有它，电商页一律被拦） |
| 三层安装器与验收脚本 | 真实费率（7 个平台 6 个费率字段全是 `null`） |

一句话：**给的是定义和工具，不是账号、数据、记忆。** 装完是一张白纸的班子，能力强弱取决于你后面喂它什么。

---

## 1. 装 DS Bot（约 10 分钟）

1. 从 **[DS-Bot Releases](https://github.com/Fei-Craft/DS-Bot/releases/latest)** 下载对应系统的包：

   | 系统 | 文件名后缀 |
   |---|---|
   | macOS Apple 芯片 | `-mac-arm64.zip` |
   | macOS Intel | `-mac-x64.zip` |
   | Windows 10/11 64 位 | `-win-x64.exe` |
   | Linux | `-linux-x86_64.AppImage` 或 `-linux-amd64.deb` |
   | Android（手机端） | `-android.apk` |

   同页的 `SHA256SUMS.txt` 用来核对下载完整性。`.blockmap`、`latest*.yml`、`ds-bot-*.tgz` 是给自动更新和插件用的，**不用下**。

   桌面版**自带一份固定版本的 DSH**，不需要另外装。截至本文写作时最新是 v0.3.10（2026-11-22 发布）。
2. 打开 **Settings → Models**，配一个可用的 provider 与模型。
   这一步只有你本人能做 —— Bot 不会问你要 key，也不要把它贴在聊天里。
3. 进主聊天，初始就有一个 **Chief**（Main Bot）。整套班子由它调度。

装完先确认两件事，不然后面全白搭：

- **Settings → Bots** 里能看到 Chief，且它的 **Model** 不是空的。
- 随便说一句话它能回 —— 回了就说明模型通了。

**macOS 提示**：未签名应用首次打开会被系统拦，走 **系统设置 → 隐私与安全性 → 仍要打开**。装不装这个包由你判断，不是本文能替你决定的。

---

## 2. 准备 node 与 git

distribution 的安装器与验收脚本要 `node`；**DS Bot 桌面版本身不需要它** —— 两者别混。

```bash
node -v        # 本机实测 v26.10.0
git --version
```

版本闸的真实口径：

- 三层安装器（L1/L2/L3）只查 `node` **可执行**，不查版本号；`l1/install.sh` 找不到时自己会试 `/opt/homebrew/bin`（写死的 macOS Homebrew 路径）。
- 只有走 **DS Bot 插件模式（DSH Web）** 时，手册才要求 Node.js 22.19 或更高。走桌面版没有这条要求。

没有 node：装 Homebrew 后 `brew install node`，或从 nodejs.org 取 LTS。

**Windows 原生跑不了** —— 三个安装器都是 bash，要 WSL 或换 Mac / Linux。

---

## 3. 拿到仓库

```bash
git clone git@github.com:ethanqing1-arch/DS-Cross-Border-Workbench.git
cd DS-Cross-Border-Workbench
```

这个仓库是 **private**，先要有权限；没有就找仓库主人加。

**下一步必须做的一改**：`distribution/l1/capability/browser-farm.json` 里 `command` 和 `args[0]` 是**本机绝对路径**，不改的话 L1 直接 FAIL。改哪两行、怎么验，见 [external-setup.md 第 1 节](external-setup.md)（那里有实测的 FAIL 原文，照着对最容易找准）。

---

## 4. 装三层

目标目录建议就用 `~/ds-bot-workspace`（团队工作区）。目录不存在没关系，安装器会自己 `mkdir -p`。

```bash
# 0) 先确认包本身没坏（装进临时目录，不碰你的工作区）
bash distribution/verify.sh
#    期望最后两行：== 汇总: PASS=61 FAIL=0 WARN=0 ==  /  RESULT: READY

# 1) L1 核心：校验 farm、写标记文件
bash distribution/l1/install.sh ~/ds-bot-workspace

# 2) L2 版本包：工作区骨架 + 业务 skills
bash distribution/l2/install.sh ~/ds-bot-workspace

# 3) L3 平台包，可装多个，重复装是幂等的
bash distribution/l3/install.sh --list                     # 看 7 个平台
bash distribution/l3/install.sh amazon ~/ds-bot-workspace

# 4) 复核：只校验不写
bash distribution/l1/install.sh ~/ds-bot-workspace --check
```

三个安装器都是**非破坏**语义：已存在的文件跳过，`--force` 才覆盖，`--check` 只校验不写（连目录都不建）。

**这一步容易误解的地方**：L1 装完只是"校验通过 + 写了个标记文件"，**并没有把工具注册进 DS Bot**。注册要手工，见 §6。

---

## 5. 起网关（只有要用 `farm_*` 浏览器工具才需要）

```bash
export GATEWAY_TOKEN='<自己生成，≥32 位>'
cd farm && bash scripts/start-gateway.sh --daemon
cd .. && curl -sS http://127.0.0.1:19671/v1/health
```

- 令牌只从环境变量读，**不要写进任何文件或命令行参数**。
- 没有 ≥32 位令牌脚本会拒绝以无鉴权方式起。
- 只装工作区、不碰浏览器的话，这一步可以跳过，前面四步照样成立。

验证鉴权是否真开着（`/v1/health` 是免鉴权端点，**不能**拿它当鉴权反证）：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19671/v1/sessions
# 期望 401
```

---

## 6. 把 7 个工具注册进 DS Bot（只有你本人能点）

五步原文在 [`distribution/l1/SEED-L1.md`](../distribution/l1/SEED-L1.md)，要点：

```
name      = browser-farm
kind      = mcp
transport = stdio
command   = <你的 node 绝对路径>
args      = ["<你的仓库>/farm/mcp/farm-mcp.js"]
env       = { GATEWAY_URL: "http://127.0.0.1:19671",
              GATEWAY_TOKEN: "$DSH_SECRET_GATEWAY_TOKEN" }
```

- `args` 必须绝对路径（stdio 启动时工作目录不确定）。
- `env.GATEWAY_TOKEN` 只写占位，真值走 DSH 的 secret。
- 挂了多个 Bot 就要逐个 `attach_capability`。
- **本地命令型 MCP 要你本人点一次 Allow**，任何 Bot 代不了。点完工具表里才出现 7 个 `farm_*`。

---

## 7. 把 11 个员工建出来

装完 L2，工作区里已有 `CHIEF-INIT.md`、`90-templates/` 和目录骨架，但 **bot 和群不会自动出现**。

做法：把 [`distribution/l2/SEED.md`](../distribution/l2/SEED.md) 交给目标机的 Chief，让它照着建。数据源都在包里：

| 文件 | 内容 |
|---|---|
| `distribution/l2/presets/bots.json` | 11 个 bot 的 `name / role / instructions` |
| `distribution/l2/presets/groups.json` | 5 个群的 `name / admin / mode / members / notice` |

建完自查：

```
list_bots                     # 11 个都在：Chief / Scout / Source / Margin / Copy /
                              # Ads / Care / Compliance / Metrics / Visual / Dev
list_bots(group="技术开发")    # 成员是 Dev，admin 是 Chief
```

两条最容易错的：

- **Dev 要单独给 `work_dir`**（技术线在独立目录，不在团队工作区）。其余 10 个留空，继承团队工作区。
- `CHIEF-INIT.md` 是原始规划稿（8 个 bot / 4 个群），**不要照它数** —— 以 `presets/` 为准，文件顶部已加注记。

工作区指向：**Settings → Bots** → 选一个 Bot → **Working folder → Folder**，填绝对路径。

`Dev` 之外那 10 个可以留空继承团队工作区 —— 但**先确认团队工作区就是 §4 装的那个目录**，否则它们会找不到 `90-templates/`。查不清的时候最稳的做法是逐个填绝对路径，别依赖继承。

> 本文不写「团队工作区」那个全局设置项的菜单名：本机验证用的 v0.3.9 与当前最新的 v0.3.10 设置结构已经重排过（v0.3.10 分成 Overview / General / Appearance / Models / Team / Connect / Tools / Usage / About 八组），写死了容易对不上。`Working folder → Folder` 这一项是稳定的。

---

## 8. 还有三件事只有你本人能做

这三件 Bot 全都代不了，别指望它自己搞定：

1. **Settings → 权限**：按 `CHIEF-INIT.md` 第 1–8 条核每个 bot 的档位。尤其 **Scout / Care 不要给终端** —— 它们的工作是读数据，不需要执行命令。
2. **Settings → IM**：把「售后风控」群接到飞书 / 钉钉（微信只支持私聊，群接不了）。IM 只是把消息送到现有团队，**不是新的沙箱、也不是权限授予**。
3. **Settings → MCP 访问**：开启后发令牌，只勾 Chief 和「选品决策」群 —— 不需要让每个 bot 都拿到浏览器工具。

---

## 9. 验收：怎么算真的能用

按顺序跑，任何一条不过就停在那条查：

```bash
# 包与安装
bash distribution/verify.sh                       # RESULT: READY

# 网关与鉴权
curl -sS http://127.0.0.1:19671/v1/health         # 200
curl -sS -o /dev/null -w '%{http_code}\n' \
     http://127.0.0.1:19671/v1/sessions           # 401

# 台账
sqlite3 farm/state/farm.db '.tables'
# 期望：accounts  checks
```

在 DS Bot 里：

```
list_bots                          # 11 个，role 与 presets 一致
farm_health                        # control 面通
```

然后给它一个真任务，比如让 Scout 读工作区里的 `90-templates/selection-score.md` 并解释字段 —— 这一步比任何 exit code 都准：它证明模型通了、工作区指向对了、文件工具能落地。

---

## 10. 装完之后仍然缺的（别当成 bug）

| 缺什么 | 后果 | 怎么补 |
|---|---|---|
| 出口代理 | 取电商详情页一律被拦，`farm` 能跑但拿不到数据 | 自备，见 [`proxy-runbook.md`](proxy-runbook.md) |
| 7 个平台的 API 授权 | 连接器全是声明，没有真实店铺数据 | 各平台开放平台申请，再填连接器 |
| 真实费率 | 定价/利润算不了准确值（全是 `null`） | 业务确认后填 `l3/platforms/*/manifest.json` |
| Amazon 专项 skill 授权 | 23 个 skill 随包交付但**对外分发授权待确认** | 见 [`REFERENCES.md`](../distribution/l3/platforms/amazon/skills/REFERENCES.md) |
| bot 的 memory | 每个员工从零开始，不继承原主 | 无捷径，只能重新带 |
| Docker | `engine=linux150` 用不了，其余引擎不受影响 | 需要时才装 |

---

## 11. 试装验收点（给第一个照着装的人）

装完按顺序回这 5 条，**每条只回「过 / 卡在第几条 / 报错原文」**。不要总结、不要翻译报错 —— 原文最能定位问题。

| # | 检查什么 | 怎么验 | 期望 |
|---|---|---|---|
| 1 | DS Bot 起来了 | 主聊天发一句话 | Chief 回复 |
| 2 | 模型配好了 | **Settings → Bots** → Chief → **Model** | 不是空 |
| 3 | 包与三层装完 | `bash distribution/verify.sh` | 末两行 `PASS=61 FAIL=0 WARN=0` / `RESULT: READY` |
| 4 | 网关鉴权真开着 | `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19671/v1/sessions` | `401` |
| 5 | 11 个员工建齐 | `list_bots` | 11 个名字与 `presets/bots.json` 一致 |

回报格式：

```
系统：<macOS 版本 / Windows 版本 / 发行版与内核>
卡在：#<编号，全过就写 0>
这一步我做了什么：
<一句话>
原文输出：
<整段贴，含 exit code>
```

全过也请回一句「5 条全过 + 系统版本」—— 我需要知道**哪一条最容易卡**，这比知道能装更重要。

---

## 一句话总结

**装得起来**：clone → 改两处路径 → 三层安装 → 注册 capability → 播种 11 个 bot，全程有脚本和自检。
**跑得动**：起网关、点 Allow、配模型，这三步必须你本人。
**用得好**：取决于代理、平台授权、真实费率这三样仓库外的东西 —— 它们不是安装问题。
