# DS-Cross-Border-Workbench

跨境电商 AI 工作台的**能力层与交付层**：把浏览器指纹农场抽成可被任意 bot 调用的共享能力（DSH capability），再把业务侧打成 L1 → L2 → L3 三层可安装包，最后补上「取页 → 判定 → 落文件」的取数通路。

配套的 DSH fork 在 [`ethanqing1-arch/deepseek-harness`](https://github.com/ethanqing1-arch/deepseek-harness)（MIT，独立仓，不设 submodule），本仓验证所用版本固定为 `4b399c39a6`（dsh 0.2.3-alpha.2，2026-11-22）。本仓不打包 DS Bot 应用本身。

## 目录

| 目录 | 是什么 |
|---|---|
| [`farm/`](farm/) | 指纹农场：control 面（`127.0.0.1:19555`）+ gateway（`127.0.0.1:19671`）+ 台账 + MCP stdio 适配层（7 个 `farm_*` 工具）+ 代理桥 |
| [`distribution/`](distribution/) | 三层分发：L1 核心包 / L2 业务版本包 / L3 平台包，加总装验收与 e2e 冒烟 |
| [`distribution/connectors/`](distribution/connectors/) | 取页探针：`ok / blocked / empty / error` 四态契约 + 七个平台的选择器预设 |
| [`docs/`](docs/) | 产品化计划、七站出口矩阵、代理 runbook、M1 增量记录 |
| `hardening/` `poc/` `probe/` `evidence/` | 早期对紫鸟客户端的逆向与指纹研究产物（历史资料，不是运行时代码） |
| `scripts/` | 早期研究脚本。注意：`scripts/proxy-bridge.js` 是研究期 PoC（凭据走 argv、只接 SOCKS5），生产用 [`farm/proxy-bridge.js`](farm/proxy-bridge.js) |

## 快速开始

```bash
# 1) 起网关（令牌只从环境变量读，永不落文件）
GATEWAY_TOKEN="$(openssl rand -hex 32)" bash farm/scripts/start-gateway.sh --daemon
bash farm/scripts/start-gateway.sh --status

# 2) 三层安装（装进目标工作区，非破坏、可重复）
bash distribution/l1/install.sh ~/ds-bot-workspace
bash distribution/l2/install.sh ~/ds-bot-workspace
bash distribution/l3/install.sh amazon ~/ds-bot-workspace   # 另有 6 个平台，--list 查看

# 3) 自检
bash distribution/verify.sh            # L1→L2→7 平台全链
bash distribution/e2e-smoke.sh         # 装链 + 真 MCP 往返 + 产物落工作区
cd farm && bash scripts/acceptance.sh --with-browser   # 跑前先 --stop 真网关（同端口）
```

## 验收基线（2026-11-23 实测）

| 自检 | 结果 |
|---|---|
| `farm/scripts/acceptance.sh --with-browser` | `PASS=67 FAIL=0 WARN=0` / `READY` |
| `distribution/verify.sh` | `PASS=61 FAIL=0 WARN=0` / `READY` |
| `distribution/e2e-smoke.sh` | `PASS=34 FAIL=0 WARN=1` / `READY`（WARN 是令牌 <32 位；farm/ 有未提交改动时改判为 33 PASS / 2 WARN，含 `transferSize>0` 反缓存假绿断言与离网 `E_GOTO` 断言） |
| `farm/scripts/test-proxy-bridge.sh` | `PASS=35`（HTTP + SOCKS5/SOCKS5H，含浏览器产品路径） |
| `farm/scripts/proxy-selftest.sh --self-test` | `PASS=12`（无真代理也能验脚本本身） |
| `farm/scripts/proxy-selftest.sh --worker-proxy` | `PASS=11 FAIL=0 INFO=1` / `READY`（camoufox worker 的真流量确实进出代理；venv 缺失时 WARN 跳过） |

计数会随覆盖收编而变，以脚本实际输出为准（本表是 2026-11-23 的一次快照）。

## 关键口径

- **网关是 REST 不是 MCP**：`/v1/*` 由 `farm/mcp/farm-mcp.js` 包成 stdio MCP，7 个工具，`kind=mcp / transport=stdio`。
- **被拦 ≠ 没数据**：取页探针先判 blocked（标题/正文/URL 路径），再判 HTTP 状态码，最后才取条目；`ok` 必须 `items ≥ 1`。
- **缓存不算取数**：导航 `transferSize === 0` 直接报 `E_CACHE_HIT`，加 `--cache-bust` 重取。
- **代理凭据不进 Chromium argv**：Chromium 不认 `--proxy-server` 里的 `user:pass`，凭据由本地桥注入；上游支持 `http://`、`socks5://`、`socks5h://`。
- **本机 DNS 是 fake-IP**（`example.com → 198.18.0.37`），生产用 `socks5h://`（远程 DNS），否则远端上游连不上 fake-IP 段。
- **令牌只从 `GATEWAY_TOKEN` / `$DSH_SECRET_GATEWAY_TOKEN` 读**，长度 < 32 位会告警。

## 当前闸门（需外部输入）

| 项 | 现状 |
|---|---|
| 网关令牌 | 本机仍 8 位，需换 ≥ 32 位后重启 |
| 目标国出口代理 | 尚无；没有它电商搜索页一律被拦（实测 eBay `Error Page`、Walmart 机器人墙） |
| 平台官方 API | 七个平台均未接授权，费率字段一律 `null` 待业务确认 |
| skill 授权归属 | 内容已随包，但 `cbec-selection-master` 是自有还是外购未定，对外分发前需确认 |

已解决：Amazon 23 个 skill 已随 L3 包分发，源 `skills/` 46 个文件逐文件比对
`OK=46 DIFF=0 MISSING=0`；`engine/`（打分引擎 + 自检 + 校验器）与 `SKILL_SPEC.md` 也已随包，
`validate_skills.py` 报 `23 通过 / 0 有问题`。

## 文档

- **从零到能用**（一台干净机器 → 11 个数字员工能干活，含 DS Bot 安装与三件只能本人做的事）：[`docs/onboard-from-zero.md`](docs/onboard-from-zero.md)
- **外部使用者从零安装**（换机器要改哪两处、八项外部依赖交接单）：[`docs/external-setup.md`](docs/external-setup.md)
- 产品化计划与里程碑：[`docs/dsh-ecom-productization-plan.md`](docs/dsh-ecom-productization-plan.md)
- 七站出口矩阵：[`docs/platform-egress-matrix.md`](docs/platform-egress-matrix.md)
- 代理 runbook（起桥、自检、407 排查）：[`docs/proxy-runbook.md`](docs/proxy-runbook.md)
- 取数 runbook（起网关 → 起桥 → 建会话带 proxy → 探针取页 → `verified` 回填）：[`docs/data-fetch-runbook.md`](docs/data-fetch-runbook.md)
- 交付层说明：[`distribution/README.md`](distribution/README.md)
- 农场说明：[`farm/README.md`](farm/README.md)

## 边界

不打包 DS Bot 应用与其商标资产；不写任何 secret 明文（凭据只走环境变量或 DSH secret）；不碰 launchd、系统设置与密码库；`farm/profiles/`、`farm/state/` 含登录态与运营数据，`.gitignore` 已排除。

本仓代码以 [`Apache-2.0`](LICENSE) 授权。有三处例外需要单独看：对 DSH 的改动受上游 MIT 许可约束，分发时需保留其版权声明；`distribution/l3/platforms/amazon/skills/` 下的 23 个 skill 源自 `cbec-selection-master`，授权归属待确认；`evidence/` 下的紫鸟文件版权归福建紫讯信息科技有限公司，仅为取证引用，不在本仓授权范围内。
