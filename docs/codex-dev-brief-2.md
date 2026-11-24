# Codex 交接单 2：L2 skill 层的三个缺口

上一轮把 `market-research` 收进 L2（commit `d3ddea2`），成为第 6 个业务 skill。
收进来之后暴露三个缺口，需要你修。

## 约束（必读）

- 只改 `distribution/l2/`、新建 `scripts/sync-l2-skill.sh`、以及相关 `docs/`。
- **不碰 `distribution/l3/platforms/amazon/`** —— 那 23 个是外部资产，来源 `cbec-selection-master`，对外授权待定。
- **不碰 `~/.ds-bot/skills/`** —— 那是 DS Bot 运行时状态，只能由同步脚本单向写入，不得由 agent 直接改。
- 不碰 DS Bot 应用状态、farm 台账与服务、launchd、系统设置。
- `distribution/l2/skills/` 与 `distribution/l2/bundle/skills/` 必须**逐文件一致**，`install.sh` 用 `diff -qr` 卡死这一点。
- 改完必须跑 `bash distribution/verify.sh`，要求末行 `RESULT: READY`。
- 拿不准的不要自己拍，写清楚卡在哪。

---

## T1 两份副本会漂

**现状**：`~/.ds-bot/skills/market-research/` 是 DS Bot 运行时在用的那份，
`distribution/l2/skills/market-research/` 是仓库那份。目前内容相同
（`diff -r` 已验证 IDENTICAL），但没有任何机制保证以后不漂。

**要做**：

1. 新建 `scripts/sync-l2-skill.sh`，单向同步「仓库 → `~/.ds-bot/skills/`」。
2. 用法 `bash scripts/sync-l2-skill.sh <skill-name> [--check]`：
   - 缺参数或 `distribution/l2/skills/<name>` 不存在 → `exit 2` 并说清原因
   - 正常模式：把该 skill 目录复制到 `~/.ds-bot/skills/<name>/`，只写不删（目标侧多余文件保留并打印提示）
   - `--check`：只比对不写；一致 `exit 0`，有差异 `exit 1` 并打印 `diff -r` 原文
3. 在 `distribution/l2/README.md`（没有就新建）写一段：**以仓库为准，拷到工作区或本机前先跑同步**，并说明这个脚本只处理 `~/.ds-bot/skills/`，不写工作区。

**验收**：

```
bash scripts/sync-l2-skill.sh market-research --check      # 期望 exit 0
# 在仓库那份里改一个字符，再跑 --check 应 exit 1 并打印差异，然后改回来
bash scripts/sync-l2-skill.sh                              # 期望 exit 2
bash scripts/sync-l2-skill.sh not-exist                     # 期望 exit 2
```

---

## T2 两个选品 skill 撞车

**现状**：`distribution/l2/skills/ecom-selection/SKILL.md`（93 行，通用版，靠 web 搜索）
和 `distribution/l2/skills/market-research/SKILL.md`（159 行，工作区特化版，读
`90-templates/` 模板 + 按 Scout 分工落盘）**都是选品总流程**。
两个同时装着，Bot 遇到「这个品能不能做」可能挑错那份。

**要做**：

在两个文件里各加一段 `### 与另一个选品 skill 的分工`，位置**紧跟在 `## 什么时候用` 这一节之后**。
内容必须给**可判定的触发边界**，不许写「看情况」「视需要」：

- 归 `market-research` 的：工作区里有 `90-templates/selection-score.md`、要出评分卡并落盘到
  `10-market/candidates/`、要走 Scout 的五步流水线并汇报给 Chief。
- 归 `ecom-selection` 的：只要一个快速判断、不落盘、不读工作区模板、当场给结论。

不要改两边已有内容的语义，只加这一节。两份镜像同步。

**验收**：

- 两个 SKILL.md 里都能搜到对方的名字
- `diff -qr distribution/l2/skills distribution/l2/bundle/skills` 无输出
- `verify.sh` READY

---

## T3 工作区路径写死

**现状**：`market-research/SKILL.md` 把工作区路径写死成 `~/ds-bot-workspace/...`，
具体在第 15–19、74、96、108–112、128 行。别人把 L2 装到别的路径，硬前置这 5 步会读不到文件。

**要做**：

1. 加一节 `## 路径解析`（放在 `## 硬前置` 之前），定义清楚：
   - 文中所有相对路径（`90-templates/…`、`10-market/…`）以**当前 Bot 的 work_dir（团队工作区根）**为基准，
     不是 shell 的 cwd；
   - 如果 Bot 没有独立 work_dir，就用团队工作区根；
   - 拿不到工作区根时，先问 Chief，不要猜路径。
2. 第 15 行那句 `~/ds-bot-workspace/README.md` 改成 `<工作区根>/README.md` 这类写法，与上面定义一致。
3. **不要删任何一步，不要改判定口径、红线阈值、打分权重**。这一步只改路径写法。

**验收**：

- 全文搜不到 `~/ds-bot-workspace`
- 硬前置仍是完整的 5 步
- `verify.sh` READY

---

## 交付

- 每项单独 commit，message 写明「改了什么 + 为什么」，不要一个 commit 混三项。
- 最后贴 `bash distribution/verify.sh` 末尾 15 行原文（不要改写）。
- 做不到的条目直说卡在哪，不要用「已优化」「已完善」这类话盖过去。
