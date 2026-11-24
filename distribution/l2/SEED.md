# SEED.md — L2 播种剧本（给 Main Bot 执行）

前置：`install.sh` 已把工作区装到目标目录，DS Bot 的共享工作区已指向该目录。
本剧本只建 bot 与群，不改模型、不改权限；模型留空用团队默认。

数据源（都在本包内，逐字使用，不要缩写、不要合并角色）：
- bot 预设：`presets/bots.json` → `bots[]`，每项 `name / role / instructions`
- 群预设：`presets/groups.json` → `groups[]`，每项 `name / admin / mode / members / notice`
- 已知例外：`Visual` 不在 `CHIEF-INIT.md` 里，instructions 是按现有职责句重建的；有正式版就先替换再建。

## 1. 建 11 个 bot（顺序执行）

对 `presets/bots.json` 的每一项调用一次 `create_bot`，参数对应：

| create_bot 参数 | 取值 |
|---|---|
| `name` | `bots[i].name` |
| `role` | `bots[i].role` |
| `instructions` | `bots[i].instructions`（原文） |
| `section` | `"跨境电商"` |
| `model` / `effort` | 不传（用团队默认） |
| `work_dir` | 只有 `Dev` 传：把 `bots[i].work_dir` 的 `<本机 …>` 占位符替换成这台机器上仓库的绝对路径（技术线不在团队工作区）；没克隆仓库就不传（继承团队工作区，并在自检里记为待补）。其余 10 个不传（继承团队工作区） |

必须建满 11 个：Chief、Scout、Source、Margin、Copy、Ads、Care、Compliance、Metrics、Visual、Dev。
建完自检：`list_bots` 里这 11 个都在，且 role 与表一致；`Dev` 的 work_dir 是这台机器上真实存在的仓库目录（没克隆仓库时为继承团队工作区，需记为待补），不是占位符本身。

## 2. 建 5 个群（bot 建完再建）

对 `presets/groups.json` 的每一项调用一次 `create_group`：

| create_group 参数 | 取值 |
|---|---|
| `name` | `groups[i].name` |
| `members` | `groups[i].members`（其余成员，不含 Chief） |
| `admin` | `"Chief"` |
| `mode` | `"admin"` |
| `notice` | `groups[i].notice`（原文） |
| `section` | `"跨境电商"` |

5 个群：选品决策（Scout/Source/Margin/Compliance）、上架交付（Copy/Compliance/Margin）、增长投放（Ads/Metrics/Copy）、售后风控（Care/Compliance/Metrics）、技术开发（Dev）。
建完自检：`list_bots(group="<群名>")` 的成员与预设一致，admin 是 Chief。

「技术开发」群的 notice 不是 CHIEF-INIT.md 原文（那份只规划电商 4 群），是照 DS Bot 现状补齐的，建之前请人工核对。

## 3. 交给用户本人做的三件事（Bot 代不了）

按 `workspace/CHIEF-INIT.md` 末尾「建完之后你自己要做的三件事」原话转给用户：

1. **设置 → 权限**：按 CHIEF-INIT 第 1–8 条核每个 bot 的档位，尤其 Scout / Care 不要给终端。
2. **设置 → IM**：把「售后风控」群接到微信或飞书（微信只支持私聊，群建议飞书/钉钉）。
3. **设置 → MCP 访问**：开启后给本机 DSH 发令牌，只勾选 Chief 和「选品决策」群。

## 4. 播种完成后回报给用户

- 团队清单：11 个 bot 的名字 / 职责 / 模型（默认即可）
- 群清单：5 个群的成员与默认 Goal
- 下一步建议：第一个 SKU 该从哪来（按工作区 `README.md` 的目录职责给具体落点）
