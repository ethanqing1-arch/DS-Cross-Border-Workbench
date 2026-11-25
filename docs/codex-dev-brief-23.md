# brief-23：交付包（能直接发给试装者）

## 背景（实测）

打包链路已经有一半了，别重造：

- `distribution/make-bundle.sh` 能出 tar.gz / ZIP / DMG，默认输出 `distribution/out`，版本号读根目录 `VERSION`（`x.y.z`），产物名 `kualang-<version>`，带 `MANIFEST.sha256`。
- `distribution/installer/first-run.command` 已经有 `doctor` → `install-all` → `verify` 三步，并且对 `--target` 做了保护（禁止落到真实 DS Bot 工作区和 `~/.dsh`）。
- `distribution/installer/FIRST-RUN.md` 已存在。
- `installer-selftest.sh` 六条断言覆盖 tar/ZIP 一致、清单校验、DMG 可读。

**缺的是「发出去就能用」这几步：**

1. `first-run.command` 装完只打印「看 README / CHIEF-INIT / data 样例」，**没有凭证自检**。客户装完了也不知道要填 SP-API / eBay 凭证，跑到取数才发现读不到——brief-22 刚把凭证接入层做好，这里必须接上。
2. 没有一条「构建 → 解包 → 真跑一遍」的端到端命令，现在只有 selftest 里各自拆开的检查。
3. 没有发布清单（发出去之前要排除什么、要核对什么），也没有试装说明。
4. **`distribution/out/` 没有被 git 忽略**（`.gitignore` 里只有 `distribution/connectors/out/`、`distribution/l2/workspace/out/*`、`distribution/l3/platforms/*/out/`），构建一次就会把几十 MB 产物挂成未跟踪文件。必须补上忽略规则并加断言。

## 任务

### T1 first-run 接入凭证自检

**文件**：`distribution/installer/first-run.command`

在 `verify` 之后加一步 `credentials`：

- 调用已安装工作区的 `scripts/credential_check.py`（brief-22 新增的那个），**不许失败退出**——客户还没填凭证是正常的；
- 打印逐项状态和一句明确的指引：去哪里填、填完跑哪条命令复核（指向 `docs/credentials-setup.md`）；
- 网关令牌缺失时提示「起网关前需要 GATEWAY_TOKEN」，但同样不阻断安装；
- 最后「下一步做什么」要列出三条：填凭证 → 跑首次取数 → 看打分表。

### T2 一键构建与端到端核验

**新文件**：`distribution/release.sh`

```
用法：bash distribution/release.sh [--out <目录>] [--dmg] [--check]
```

- 默认输出到 `distribution/out`；
- 构建后**自动做一遍端到端**：解包 ZIP 到临时目录 → 校验 `MANIFEST.sha256` → 在临时工作区跑 `first-run.command --target <临时目录>` → 确认退出码 0；
- `--check` 只做核验，不重建。

### T3 发布前清单与试装说明

**新文件**：`docs/release-checklist.md`

必须包含：

- **构建前**：`git status` 干净、`VERSION` 已递增、`verify.sh` / `flow-smoke.sh` 全过；
- **产物必须排除**：真实凭证、`farm/state/*.db`、`farm/profiles/`、`distribution/out` 自身、任何 `*.pem` 私钥、`.env`；
- **产物必须包含**：`LICENSE`、`VERSION`、`distribution/`、`docs/`、`farm/`（不含 state 与 profiles）、`MANIFEST.sha256`；
- **发出去之前**：在干净目录解包跑一次 `release.sh --check`，把结果贴进发布记录；
- **试装者怎么用**：解压 → 双击 `first-run.command` → 装完填凭证 → 跑一次取数。

**更新**：`distribution/installer/FIRST-RUN.md` 补「填凭证」章节，链到 `docs/credentials-setup.md`。

### T4 断言

**`distribution/installer-selftest.sh`** 增加两条：

1. 解包后的 `first-run.command` 里**确实调用了** `credential_check.py`（grep 断言，防止以后被删掉）；
2. 产物里**不含**私钥、`farm/state/*.db`、`farm/profiles/`、`.env`（遍历断言，命中即 FAIL）。

**`distribution/verify.sh`** 增加一节 `7h. 发布包`：至少三条——
1. `release.sh --check` 退出码 0（用临时 `--out`，不许写到真目录）；
2. 产物里能找到 `docs/credentials-setup.md`；
3. 产物不含上面列的禁止项；
4. `git status --porcelain` 在构建后仍然干净（证明 `distribution/out/` 已被忽略）。

### T5 文档

- `README.md`：加「怎么发给别人装」三行（构包 → 解包 → 双击）。
- `docs/roadmap.md`：「装」那行的证据补一句「有可发布的 ZIP/DMG 产物」。

## 范围与红线

- **只许改**：`distribution/installer/first-run.command`、新建 `distribution/release.sh`、新建 `docs/release-checklist.md`、`distribution/installer/FIRST-RUN.md`、`distribution/installer-selftest.sh`、`distribution/verify.sh`、`README.md`、`docs/roadmap.md`、`.gitignore`（只许加 `distribution/out/` 一行）、本交接单「收尾」。
- **不许改**：`make-bundle.sh`（除非发现真实 bug，且必须在收尾里写明改了什么、为什么）、任何 `scripts/*.py`、`farm/`、`score_products.py`、`credential_check.py`。
- **红线**：
  - 产物里绝不允许出现真实凭证、私钥、台账数据库、浏览器 profile；
  - `first-run.command` 的凭证自检**不许失败退出**（客户没填凭证是正常状态）；
  - 不许把 `--target` 的保护逻辑删掉或放宽（它会禁止落到 DS Bot 真实工作区）；
  - 构建过程不许需要联网。
- 镜像同步：`distribution/l2/skills` 与 `distribution/l2/bundle/skills` 的 `diff -qr` 必须零差异。
- **不要 commit、不要 push**，改完停在干净工作区等我验收。

## 收尾

把下面原文追加到本文件末尾：

1. `bash distribution/verify.sh` 汇总行 + `7h` 三条原文；
2. `bash distribution/installer-selftest.sh` 汇总行 + 新增两条原文；
3. 一次真实构建的完整输出（`release.sh`，含产物路径与大小）；
4. 解包后 `first-run.command` 的凭证自检那几行原始输出；
5. `ls -la` 产物目录 + `shasum -c MANIFEST.sha256` 结果；
6. `diff -qr` 镜像结果（应为空）。
