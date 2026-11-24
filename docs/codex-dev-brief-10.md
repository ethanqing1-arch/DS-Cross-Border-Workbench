# Codex 交接单 10：降级链运行时 + roadmap 校准 + doctor 口径统一

## 背景（现状是我核过的）

三件互不相干但都不依赖外部条件的事，打包一单：

1. **降级链运行时缺失**：`tier` 只写在平台 manifest 的 `connectors[]` 里，代码里没有按 tier 调度。证据（我跑的）：
   ```
   $ grep -rn "tier" farm/gateway/server.js farm/contract.js
   (无输出)
   ```
   现在 `ebay-api`（T1）与 `browser-farm`（T3）都只是声明；没有任何组件在「T1 不可用」时自动降级到 T3，也没记录降级原因。
2. **roadmap 数字过期**：`docs/roadmap.md:16` 写 `PASS=63`（现在 65），`:18` 写「7 平台 API 全未接」（eBay 已接 L2 connector），`:75` 写「代码里没有任何调度按 tier 走」（本单要改掉）。
3. **doctor 与 install 口径不一致**：`distribution/doctor.sh:40` 直接 `command -v node`，没有 fallback；`distribution/l1/install.sh:20` 会自动补 `/opt/homebrew/bin`。结果：同一台机器 `install.sh` 能装，`doctor.sh` 却 FAIL「PATH 里找不到 node」。

## 约束（必读）

- 不要碰 `farm/`（引擎、台账、profiles、正在跑的 gateway / control）。
- 不要动 `farm/state/farm.db`、`farm/profiles/`、`~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- 只新增/修改：`distribution/l2/workspace/scripts/fetch_router.py`、`distribution/connectors/router-selftest.sh`、`distribution/verify.sh`、`distribution/doctor.sh`、`docs/trial-kit.md`、`docs/roadmap.md`。
- 系统 `python3` 是 `3.9.6`，客户端零依赖、只用标准库。
- 令牌/密钥只从环境变量读，不进 argv、不落文件、不打印。
- 拿不准就停，写清卡点；**不许伪造数字**。
- 改完自己 commit，只提交你改/加的文件。

---

## T1 降级链 `distribution/l2/workspace/scripts/fetch_router.py`

零依赖、Python 3.9 兼容。职责：按平台 manifest 声明的 tier 顺序调度，T1 失败降 T3，全过程记录 attempts。

```bash
python3 scripts/fetch_router.py run --platform ebay --need search \
  --q "wireless earbuds" --site EBAY_US --limit 20 --out out/
```

**tier 从哪读**：按优先顺序找 manifest —— `--manifest <path>` → `./95-engine/platforms/<p>/manifest.json` → 脚本自身相对的 `<分布根>/l3/platforms/<p>/manifest.json`。找不到 → `E_ROUTER_CONFIG` 退出码 2。

**调度规则**：

- 只认 manifest `connectors[]`：`tier == "T1"` 且 `id != "browser-farm"` 的按声明顺序排；`id == "browser-farm"` 作 T3 最后兜底。
- 每个 tier 一个适配器，失败**不中断**，记 `attempts[]` 后继续下一个：
  - T1 `ebay-api`：调用同目录 `ebay_fetch.py`（`sys.executable` + 原参数）。子进程退出码 2（缺凭证）→ `skipped` + `reason: "E_EBAY_CONFIG"`；3/4/5/6 → `failed` + 对应 code；0 → `ok`。
  - T1 其他 id（`walmart-marketplace-api`、`tiktok-shop-api` …）：`skipped` + `reason: "connector_not_implemented"`，**不许假装调过**。
  - T3 `browser-farm`：默认跑 `node <分布根>/connectors/farm-probe.js --platform <p> --query <q> --out <tmp>`（`--t3-cmd` 可替换整条命令，供自检注入）。退出码 0 → `ok`；2 → `blocked`（failed，`reason:"blocked"`）；3 → `empty`（failed）；1 → `error`；找不到 node/脚本 → `skipped` + `reason: "t3_unavailable"`。
- 第一个 `ok` 即停：后面 tier 记 `skipped` + `reason:"not_needed"`。

**输出**：

- 落 `--out` 目录 `fetch_<platform>_<UTC时间戳>.json`，含 `{platform, need, args, tier_used, fallback, attempts[], result}`；
- stdout 只一行 JSON 摘要：`{"tier_used": "...", "fallback": true|false, "out": "<path>"}`；
- 全 tier 都没成 → stderr 结构化 `{"code":"E_NO_TIER","attempts":[...]}`，退出码 7；
- 任何输出与文件里**不得出现凭证值**。

**错误码**：`E_ROUTER_CONFIG`=2、`E_NO_TIER`=7；其余沿用被调方 code。

---

## T2 自检 `distribution/connectors/router-selftest.sh`

复用 `ebay_mock.py`（已存在）+ 两个临时 T3 桩。断言：

1. **T1 可用**：起假服务、给假凭证 → `tier_used="T1"`、`fallback=false`、输出文件有 `tier_used`；
2. **降级**：不给凭证、T3 桩退出 0 → `tier_used="T3"`、`fallback=true`，`attempts[0].status="skipped"` 且 `reason="E_EBAY_CONFIG"`；
3. **全不可用**：不给凭证、T3 桩退出 1 → 退出码 7、stderr `code=E_NO_TIER`，`attempts` 里两条都在；
4. **不许静默成功**：上面两种失败场景 stdout 都必须为空；
5. **凭证不外泄**：所有 stdout/stderr/输出文件里不含 `mock-secret`、`mock-token`。

输出沿用约定：`PASS/FAIL` + `== 汇总: PASS=n FAIL=0 WARN=0 ==` + `RESULT: READY`。

**`distribution/verify.sh` 改动两处**：

1. 新增「7b. 降级链」聚合断言（跑 `router-selftest.sh`），`PASS=65 → 66`；
2. 随包脚本清单加 `scripts/fetch_router.py`，文案「6 个」→「7 个」。

---

## T3 doctor 口径

`distribution/doctor.sh` 第 40 行前补与 `l1/install.sh:20` 相同的 fallback：

```bash
if ! command -v node >/dev/null 2>&1; then export PATH="/opt/homebrew/bin:$PATH"; fi
```

要求：补到 node 后仍要**明确告诉用户**原始 PATH 里没有 node（`WARN` 一条，说明已用 `/opt/homebrew/bin` 兜底），node 版本检查通过则保留 `PASS node vX.Y`。找不到仍照原样 `FAIL`。

`docs/trial-kit.md:61` 那行「FAIL PATH 里找不到 node → 自己加 PATH」改成：doctor 会用 `/opt/homebrew/bin` 兜底并 WARN；仍 FAIL 才需要手动加。

---

## T4 roadmap 校准（按本单改完后的实测数字）

`docs/roadmap.md` 至少改这几处，其它数字别动：

| 位置 | 现状 | 改成 |
|---|---|---|
| `:16` | `PASS=63` | `PASS=66` |
| `:18` 取数行 | 「7 平台 API 全未接」 | eBay 已接 L2 connector（`scripts/ebay_fetch.py` + 假服务自检）；其余 6 个未接；真端点均未验证 |
| `:41` 0.5 | 只说 profiles 已删 | 补：台账 5 行 = 1 running（`default:mkt-probe-amazon`）+ 3 stopped 待清 + 保留 `default:e2e-smoke` |
| `:75` 2.2 | 「代码里没有任何调度按 tier 走」 | 已补 `fetch_router.py`（T1→T3 降级、attempts 记录、T2 未声明则不参与）；真实 T1 通才算阶段 2 完成 |
| `:100` 阶段 4 | 「其余 6 平台专项 skill」 | 5 个平台专项 skill 未做；eBay 只有 L2 `ecom-ebay`，L3 `skills/` 仍空 |
| `:132` 附录 | `PASS=63` | `PASS=66` |

---

## 验收（贴原文）

```bash
bash distribution/connectors/router-selftest.sh        # PASS=n FAIL=0 / READY
bash distribution/verify.sh                            # PASS=66 FAIL=0 WARN=0 / READY
bash distribution/flow-smoke.sh                        # PASS=8 FAIL=0 WARN=0（回归）
env PATH=/usr/bin:/bin bash distribution/doctor.sh     # 出现 WARN 兜底 + PASS node，RESULT 不变差
bash distribution/l2/install.sh /tmp/rt-ws              # skills=8；工作区有 scripts/fetch_router.py
rm -rf /tmp/rt-ws
```

`doctor.sh` 那条要在**去掉 /opt/homebrew/bin 的 PATH 下**跑，`RESULT` 由原有环境决定，只要 node 那行从 FAIL 变 PASS（或 WARN 兜底 + PASS）。

---

## 回报格式

```
T1：--help 原文 + 三次运行（T1 命中 / 降级 / E_NO_TIER）的 stdout+stderr+退出码
T2：router-selftest 末尾原文 + verify 末尾原文 + flow-smoke 末尾原文
T3：PATH 剥离下 doctor 的 node 行与 RESULT 原文 + trial-kit 改动行
T4：roadmap 改动行（文件:行）+ 改后 grep 原文
```

卡住就停在原地写清：哪一行、什么错、试过什么。
