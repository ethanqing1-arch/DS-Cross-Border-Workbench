# L2 · kualang-cbec（跨境电商业务版本包）

装三样东西：

| 内容 | 落点 |
|---|---|
| 工作区骨架（6 个模板 + `CHIEF-INIT.md` + 目录结构） | `<目标目录>/` |
| 6 个业务 skill | `<目标目录>/.dsh/skills/` |
| 11 个 bot / 5 个群预设 + 播种剧本 | 不进目标目录，由 Main Bot 按 [`SEED.md`](SEED.md) 建 |

## 安装

```bash
bash install.sh ~/ds-bot-workspace
bash install.sh ~/ds-bot-workspace --check     # 只校验，不写任何文件
```

非破坏语义：已存在的文件跳过，`--force` 才覆盖。

## 6 个业务 skill

| skill | 用途 |
|---|---|
| `ecom-selection` | 选品分析（通用版：当场结论，不落盘、不读工作区模板） |
| `market-research` | 选品主控 SOP（工作区版：出评分卡、落盘 `10-market/`、按 Scout 分工汇报） |
| `ecom-listing` | 上架文案 |
| `ecom-ops` | 运营日常 |
| `ecom-cs` | 客服话术 |
| `ecom-guardrails` | 合规红线 |

`ecom-selection` 和 `market-research` **都是选品流程**，两个同时装着。它们各自 SKILL.md
里有一段「与另一个选品 skill 的分工」，按「要不要落盘 / 工作区里有没有 `90-templates/selection-score.md`」
来分，不要两套混用。

## 以仓库为准：同步到本机

`skills/` 是唯一事实源，但 DS Bot 运行时读的是 `~/.ds-bot/skills/<name>/` —— 两边会漂。
改完仓库那份，同步过去：

```bash
bash ../../scripts/sync-l2-skill.sh market-research          # 单向同步，只增改不删
bash ../../scripts/sync-l2-skill.sh market-research --check  # 只比对；一致 exit 0，有差异 exit 1 并打印 diff
```

- 只处理 `~/.ds-bot/skills/`，**不写**工作区、不装 bundle、不碰 DS Bot 应用状态。
- 目标根可用 `DSBOT_SKILLS_DIR` 覆盖（例如 `DSBOT_SKILLS_DIR=/tmp/t bash ../../scripts/sync-l2-skill.sh <name>`）。

## 两份镜像必须一致

`skills/` 与 `bundle/skills/` 是同一批内容的两个副本 —— `install.sh` 用 `diff -qr` 卡死
这一点，只改一边会直接 FAIL。任何改动后跑：

```bash
rsync -a distribution/l2/skills/ distribution/l2/bundle/skills/
diff -qr distribution/l2/skills distribution/l2/bundle/skills   # 应无输出
```

## 装完还要做什么

`install.sh` 只写文件。接下来：

1. 起网关并在 DS Bot 里注册 `browser-farm` capability（见 `distribution/l1/SEED-L1.md`）
2. 把 [`SEED.md`](SEED.md) 交给 Chief，建 11 个 bot 和 5 个群
3. 三件只有你本人能做的事：**Settings → 权限**、**Settings → IM**、**Settings → MCP 访问**

完整顺序见仓库根的 [`docs/onboard-from-zero.md`](../../docs/onboard-from-zero.md)。
