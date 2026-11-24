# 外部使用者安装指南：从 clone 到跑通

前提：机器上**已经有 DS Bot，且模型可用**。如果还没有，先看
[`onboard-from-zero.md`](onboard-from-zero.md) 第 1 节，再回来看本文。

目标：别人拿到这个仓库，照本文能起网关、装上三层、在 DS Bot 里验到 7 个 `farm_*` 工具。

边界：本文只讲「怎么装」和「装不上时先看哪一条」。业务取数看
[`data-fetch-runbook.md`](data-fetch-runbook.md)，代理排查看 [`proxy-runbook.md`](proxy-runbook.md)。

---

## 一句话结论

仓库给的是**代码 + 安装器 + skill + 文档**。真正跑起来还差 8 样仓库外的东西：
其中 **1 样是必须改**（clone 路径写死在载荷里），**7 样要各自备**。

仓库不含：DS Bot 本体、任何 secret、出口代理、平台 API 授权。

---

## 0. 前置清单

| 项 | 必需性 | 本机实测 | 不满足时 |
|---|---|---|---|
| Bash | 必须 | macOS 自带 | Windows 原生不行，见 §8 |
| Node | 必须 | `v26.10.0` | `start-gateway.sh` 直接 `exit 2` |
| Git | 必须 | 有 | clone 不了 |
| DS Bot | 必须 | 有 | 没有宿主，装完也没地方注册 |
| `GATEWAY_TOKEN` | 必须 | 现在 8 位（偏短，需换 ≥32） | `start-gateway.sh` 拒绝以无鉴权方式起 |
| Chrome 或 fingerprint-chromium | 视引擎 | 两个都在 | 起会话才失败，`/v1/health` 照样 200 |
| Python 3.13 + camoufox + fpgen 模型 | 可选 | `~/.dsh/venvs/camoufox`，3.13.16 + camoufox 0.5.9 | 只影响 `engine=camoufox` |
| Docker | 可选 | **没有**：`docker: command not found` | 只影响 `engine=linux150` |
| 出口代理 | 业务必须 | **没有** | 安装不影响；取电商页一律被拦 |

硬性版本闸：脚本只查 node **可执行**、不查版本号；`CAMOUFOX_PY` 有版本闸，必须是 3.13。

---

## 1. clone，并改掉载荷里的两处绝对路径 ← 最容易漏

`distribution/l1/capability/browser-farm.json` 里 `command` 和 `args[0]` 是**本机绝对路径**，
不是相对路径。别人 clone 到别处照原样跑，L1 会直接 FAIL。

实测（把 `args[0]` 改成别人的路径后跑只校验）：

```
$ bash /tmp/l1-copy/install.sh /tmp/target --check --farm <farm>
  FAIL args[0] 未指向当前 farm：/home/other/repo/farm/mcp/farm-mcp.js
  FAIL capability 载荷校验不通过（见上行原因）
  FAIL 前置校验未过，不写标记文件
== CHECK: would-write=0 would-skip=0 FAIL=1 ==
CHECK FAILED
```

按自己机器改（本条命令会改写仓库里那一个 json）：

```bash
REPO="$HOME/Projects/DS-Cross-Border-Workbench"
git clone git@github.com:ethanqing1-arch/DS-Cross-Border-Workbench.git "$REPO"
cd "$REPO"

NODE_BIN="$(command -v node)"
node -e '
const fs = require("fs");
const p = "distribution/l1/capability/browser-farm.json";
const c = JSON.parse(fs.readFileSync(p, "utf8"));
c.command = process.argv[1];
c.args = [process.argv[2]];
fs.writeFileSync(p, JSON.stringify(c, null, 2) + "\n");
' "$NODE_BIN" "$PWD/farm/mcp/farm-mcp.js"
```

验（只写临时目录，不动仓库）：

```bash
bash distribution/l1/install.sh /tmp/l1-check --check
# 期望：CHECK OK（未写任何文件），FAIL=0
```

`env.GATEWAY_TOKEN` 必须保持字符串 `$DSH_SECRET_GATEWAY_TOKEN` 不动 —— L1 会检查它是不是占位，
写进真令牌会被判成明文 secret。

---

## 2. 令牌

```bash
openssl rand -hex 32        # 64 位
```

存进 DS Bot 的密钥（名字 `GATEWAY_TOKEN`），不要写进任何文件、不要进 argv。
长度 < 32 只会 WARN（`first-fetch.sh`、`e2e-smoke.sh` 都这么判），但别将就。

---

## 3. 起网关

```bash
cd "$REPO/farm"
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash scripts/start-gateway.sh --daemon
bash scripts/start-gateway.sh --status
```

期望看到 `control: up pid=…` 和 `gateway: up pid=…`。

验（健康端点是**免鉴权**的，不能拿它当鉴权证据）：

```bash
curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:19671/v1/health
# 期望 HTTP=200，body 里有 version / contract_version / engines

printf 'header = "Authorization: Bearer %s"\n' "$DSH_SECRET_GATEWAY_TOKEN" \
  | curl -sS -K - -o /dev/null -w 'HTTP=%{http_code}\n' http://127.0.0.1:19671/v1/sessions
# 期望 HTTP=200

curl -sS -o /dev/null -w 'HTTP=%{http_code}\n' http://127.0.0.1:19671/v1/sessions
# 期望 HTTP=401
```

两个已知的口径陷阱：

- `/v1/health` 里 `engines.chromium: "up"` 只代表 **control 面通**，不代表引擎真起过。要验引擎得建会话跑任务。
- 健康端点带 `?probe=1` 会真起临时实例，慢；`camoufox` 探针只到模块层，不启动浏览器。

---

## 4. 装三层

顺序不能反：L2 依赖 L1 的标记，L3 依赖 L2 的骨架。

```bash
cd "$REPO"
bash distribution/l1/install.sh ~/ds-bot-workspace
bash distribution/l2/install.sh ~/ds-bot-workspace
bash distribution/l3/install.sh amazon ~/ds-bot-workspace    # 另有 6 个平台，--list 查看
```

平台清单（`bash distribution/l3/install.sh --list` 原文）：

```
  aliexpress  baseline  AliExpress 速卖通
  amazon      full      Amazon 美国站
  ebay        baseline  eBay
  lazada      baseline  Lazada
  shopee      baseline  Shopee
  tiktokshop  baseline  TikTok Shop
  walmart     baseline  Walmart
```

`amazon` 是唯一 `full` 档，包里实测 **46 个 `SKILL.md`**（`skills/` 与 `bundle/` 各一套 23 个）。
`manifest.json` 的 `source` 字段指向上游桌面目录，那是**来源声明**、不是安装依赖 —— 装的时候不读它。

amazon 包还带三样非 skill 的东西，装完都在 `<目标目录>/95-engine/platforms/amazon/`：

| 路径 | 用途 | 要不要额外依赖 |
|---|---|---|
| `engine/score.py` | 选品打分（四维打分 + 三层利润 + 硬红线） | 只用标准库；出 Excel 才要 `openpyxl` |
| `engine/selftest.py` | 引擎自检，128 项断言 | 无 |
| `engine/validate_skills.py` | 校验 23 个 skill 结构 | 无 |
| `data/candidates_sample.csv` | 12 行纯样例候选，引擎默认输入 | 无 |
| `SKILL_SPEC.md` | 23 个 skill 的写作规范（唯一事实源） | 无 |

开箱验（2026-11-24 实测）：

```bash
cd <目标目录>/95-engine/platforms/amazon
python3 engine/validate_skills.py   # 结果：23 通过 / 0 有问题
python3 engine/selftest.py          # 自检 128 项断言 → ✓ 全部通过
python3 engine/score.py             # 写 out/<run_id>/ 四件套，退出码 0
```

`out/` 是运行产物，不入库（`.gitignore` 已排除 `distribution/l3/platforms/*/out/`）；
`engine/__pycache__` 同理，安装枚举也排除了它，所以「落点文件数 = 源文件数」不会因为谁跑过引擎而而变化。

### 4.1 把数字员工建出来（11 个 bot / 5 个群）

装完 L2，工作区里就有了 `CHIEF-INIT.md`、`90-templates/` 与目录骨架，但**bot 和群不会自动出现** ——
它们要靠 Main Bot（Chief）调 `create_bot` / `create_group` 建。

数据源都在包里，照抄即可，不要自己缩写角色：

| 文件 | 内容 |
|---|---|
| `distribution/l2/presets/bots.json` | 11 个 bot 的 `name / role / instructions`（含 Dev，它带独立 `work_dir`） |
| `distribution/l2/presets/groups.json` | 5 个群的 `name / admin / mode / members / notice` |
| `distribution/l2/SEED.md` | 给 Main Bot 执行的播种剧本（包含 create 参数映射与自检） |

做法：把 `SEED.md` 交给目标机的 Chief，让它按顺序建。建完自查：

```
list_bots            # 11 个都在：Chief / Scout / Source / Margin / Copy / Ads / Care / Compliance / Metrics / Visual / Dev
list_bots(group="技术开发")   # 成员是 Dev，admin 是 Chief
```

两条容易错的：

- **Dev 要单独给 `work_dir`**（技术线在 `~/Projects/DS-Cross-Border-Workbench`，不在团队工作区）。
  其余 10 个不传，继承团队工作区。
- `CHIEF-INIT.md` 是原始规划稿（8 个 bot / 4 个群），**不要照它数**；它以 `presets/` 为准。
  文件顶部已加注记。

还有三件事 Bot 代不了，得用户本人做（见 `SEED.md` 第 3 节）：**设置 → 权限**核每档位、
**设置 → IM** 接群、**设置 → MCP 访问**发令牌。

**数字员工的 memory 不随包**：每个 bot 的长期记忆是它自己的，换机器从零开始。
仓库给的是「定义 + 工作区 + skill + capability」，不是它们的对话历史。

---

## 5. 在 DS Bot 里注册 capability

装包只写 `<目标>/.dsh/kualang-l1.json` 标记文件，**真正的注册必须人工做**（五步原文见
[`distribution/l1/SEED-L1.md`](../distribution/l1/SEED-L1.md)）：

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
- `env.GATEWAY_TOKEN` 只能写占位，真值由 DSH 注入。
- 挂了多个 Bot 就要每个都 `attach_capability`。
- 本地命令型 MCP 要 **用户本人点一次 Allow**，任何 Bot 代不了。点完工具表里才出现 7 个 `farm_*`。

---

## 6. 验收三条

```bash
cd "$REPO"
bash distribution/verify.sh                    # 自包含，只写 mktemp 目录，不碰 farm
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash distribution/e2e-smoke.sh   # 要网关在跑
ACCEPT_PORT=19681 ACCEPT_CONTROL_PORT=19581 bash farm/scripts/acceptance.sh --with-browser
```

README 里 2026-11-24 的快照基线（数字会随覆盖变化，以脚本实际输出为准）：

```
farm/scripts/acceptance.sh --with-browser  PASS=72 FAIL=0 WARN=0 / READY
distribution/verify.sh                     PASS=63 FAIL=0 WARN=0 / READY
distribution/flow-smoke.sh                 PASS=8 FAIL=0 WARN=0 / READY（网关 19671 在跑；离线时 L1、L2 各一条 WARN）
distribution/e2e-smoke.sh                  PASS=34 FAIL=0 WARN=1 / READY（WARN 是令牌 8 位 <32；须单跑）
```

`e2e-smoke.sh` 走 `GATEWAY_URL`（默认 `http://127.0.0.1:19671`）指向的现有网关，令牌取 `GATEWAY_TOKEN` 或 `DSH_SECRET_GATEWAY_TOKEN`；令牌 <32 位时多 1 条 WARN（8 位即为本例）。它必须与其它浏览器自检错开跑：并发会因资源争抢报 `E_TIMEOUT` 假红。

---

## 7. 八项交接单

| # | 缺什么 | 谁提供 | 没有时会发生 | 怎么补 |
|---|---|---|---|---|
| 1 | DS Bot 本体 | 用户自己装 | 没有宿主，装完无处注册 | 装 DS Bot，仓库不打包（含商标资产也不打包） |
| 2 | Node | 用户自己装 | `start-gateway.sh` → `exit 2` | 装 Node；非 Homebrew 机器见 §8 |
| 3 | Chrome / fingerprint-chromium | 用户自己装 | `/v1/health` 照样 200，**起会话才失败** | 装 Chrome 或用 `CHROME_BIN` / `FP_CHROME_BIN` 指路径 |
| 4 | `GATEWAY_TOKEN` | 用户自己生成 | 拒绝以无鉴权方式起网关 | `openssl rand -hex 32`，存 DSH 密钥 |
| 5 | Python 3.13 + camoufox + fpgen 模型 | 用户自己装 | 只影响 `engine=camoufox`，其余引擎不受影响 | §7.1 |
| 6 | Docker | 用户自己装 | 只影响 `engine=linux150`（本来就是 `unverified`） | 装 Docker 后跑 `farm/docker/` |
| 7 | 出口代理（目标国） | 用户自己买 | 安装不受影响；**取电商页一律被拦**（实测 eBay `Error Page`、Walmart 机器人墙） | 见 `proxy-runbook.md` |
| 8 | 平台官方 API 授权 | 用户自己申请 | 费率字段一律 `null`，对账跑不了 | 按平台申请 SP-API 等 |

### 7.1 camoufox（可选引擎）

必须 3.13：3.14+ 能 `import` 但生成指纹会崩，3.15 实测 `binascii.Error: Incomplete Base85 group` / `TargetClosedError`。

```bash
python3.13 -m venv ~/.dsh/venvs/camoufox
~/.dsh/venvs/camoufox/bin/pip install camoufox
~/.dsh/venvs/camoufox/bin/python -m camoufox fetch    # 浏览器本体，mac.arm64 约 1.3 GB
```

放 `~/.dsh/venvs/camoufox` 不是随便定的：`start-gateway.sh` 会**自动探测**这个路径并
`export CAMOUFOX_PY`，还会打印 `CAMOUFOX_PY_VERSION=`；不是 3.13 打警告但**不拒绝启动**。
放别处就要每次手动带 `CAMOUFOX_PY=<解释器>`。

首次启动还要装 fpgen 的 pinned 模型，官方路径走 `github.com/.../releases/download/...`。
在 `github.com` 连不通的网络上会卡在 `SYN_SENT → cdn-*.github.com`；可走 `api.github.com`
资产口下同一份文件（`Accept: application/octet-stream`），按 `fpgen-model.json` 的 sha256
逐个校验后写入 `site-packages/fpgen/data/`，mtime 设 `2145916800`，再写 `.pinned-model` 戳。
**不要降完整性门槛**。

---

## 8. 平台差异

| 平台 | 状态 | 说明 |
|---|---|---|
| macOS Apple Silicon | 当前基线 | 本机就是；浏览器默认 `/Applications/...` |
| macOS Intel | 需改 | `/opt/homebrew/bin` → `/usr/local/bin`；`farm.js` 的浏览器默认路径同样要覆盖 |
| Linux | 需改 | 无 `/Applications/*.app`；用 `CHROME_BIN` / `FP_CHROME_BIN` 指二进制 |
| Windows | 不支持 | 脚本是 bash、路径是 `/Applications/*.app`，没有 PowerShell 版 |

`/opt/homebrew/bin` 这个兜底出现在 4 个脚本里（`l1/install.sh`、`l3/install.sh`、
`verify.sh`、`e2e-smoke.sh`）。它只在 `command -v node` 失败时才 `export PATH`，
所以 **node 已在 PATH 里就不影响**；不在才需要改成对应路径。

---

## 9. 失败对照表

| 现象 | 先看这条 |
|---|---|
| `GATEWAY_TOKEN 未设置，拒绝以无鉴权方式起网关` | §2，令牌没传进去 |
| `FAIL args[0] 未指向当前 farm` | §1，没改载荷路径 |
| `FAIL command=/opt/homebrew/bin/node 与本机 node 不一致` | §1/§8，改 `command` |
| `FAIL env.GATEWAY_TOKEN 是明文 secret` | §1，占位被写成了真令牌 |
| `WARN 网关不可达或未就绪` | **不挡安装**，只说明网关没起或端口不对 |
| `health` 里 camoufox `unverified` | §7.1，`CAMOUFOX_PY` 没指到 3.13 |
| `E_UNSUPPORTED_TASK`（422） | 该引擎不支持这个任务类型，看 `/v1/version` 和 `contract.js` 的 `ENGINE_CAPS` |
| 任务 502 且换 key 就好了 | `Idempotency-Key` 复用了上次失败的响应（缓存 24h），换一个 key |
| 取页探针报 `E_CACHE_HIT` | `farm-probe.js` 层：导航 `transferSize === 0`，加 `--cache-bust` 重取 |
| 取页探针报 `E_GOTO` | `final_url` 以 `chrome-error://` 开头，是出口/网络不通，**别按缓存排障** |

---

## 边界

- 本仓不含 DS Bot 应用与其商标资产；DSH 改动受上游 MIT 约束，分发需保留版权声明。
- 不含任何 secret；`farm/profiles/`、`farm/state/`、`*.db`、`node_modules/` 已在 `.gitignore`。
- 本仓代码以 **Apache-2.0** 授权（见根目录 `LICENSE`）。例外看 README「边界」：DSH 改动受上游 MIT 约束、
  `amazon/skills/` 下的 23 个 skill 授权归属待确认、`evidence/` 下的紫鸟文件不属本仓授权。
