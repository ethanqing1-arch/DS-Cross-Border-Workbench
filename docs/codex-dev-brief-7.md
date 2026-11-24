# Codex 交接单 7：发行包 + 一键安装 + 环境体检 + 试装包

## 背景（现状是我今晚实测的）

阶段 0 已完成：`verify.sh` = `PASS=63 FAIL=0 WARN=0`，`acceptance --with-browser` = `PASS=72 FAIL=0 WARN=0`，`e2e` 单跑 `PASS=34 FAIL=0 WARN=1`、并发 `SKIP` exit 3。

但「别人拿到」这一步还是散的：要手动跑 3 层 install、没有任何环境体检、没有试装说明、没有可交付的发行包。这一单把这四件事做完。

**仓库体积**：`farm/` 377M，其中 `farm/profiles/` 375M（浏览器登录态，绝对不能进包）、`farm/state/` 1.2M（台账）；`farm/node_modules/ws` 只有 200K（离线跑要带上）。

## 约束（必读）

- 不要停/重启 gateway（pid `31679` @19671）或 control（pid `99944` @19555），不要 kill 浏览器（Chromium `23934`）。
- 不要动 `farm/state/farm.db`、台账、`farm/profiles/`、`~/.ds-bot/skills/`、`distribution/l3/platforms/amazon/`、`evidence/`。
- 令牌只从环境变量读，不进 argv、不落文件、不打印。
- 新增文件只放在 `distribution/`、`docs/`，改 README 时只在入口节加行。
- 拿不准就停，写清卡点；**不许伪造 PASS 数字**。
- 改完自己 commit，只提交你改/加的文件。

---

## T1 发行包 `distribution/make-bundle.sh`

**要做的**：一条命令打出可交付的 tarball。

**用法**：

```bash
bash distribution/make-bundle.sh                 # 产出到 distribution/out/（gitignore 已忽略 out/）
bash distribution/make-bundle.sh --out /tmp/bx   # 指定输出目录
```

**要求**：

1. 版本号：新建仓库根 `VERSION` 文件（内容 `0.1.0`），脚本读它；包名 `dsh-ecom-0.1.0.tar.gz`，解压后顶层目录 `dsh-ecom-0.1.0/`。
2. **白名单**只打这些：`LICENSE`、`README.md`、`CONTRIBUTING.md`、`VERSION`、`distribution/`（排除 `distribution/out/`）、`farm/`（排除 `farm/state/`、`farm/profiles/`、`*.db`、`*.db-*`、`__pycache__`）、`docs/`；`farm/node_modules/ws` 要带上（离线可跑）。`scripts/`、`evidence/`、`poc/`、`probe/`、`hardening/`、`.git/` 都不进包。
3. 生成 `MANIFEST.sha256`（包内每文件一行 sha256）放在包内根目录；脚本最后打印 tarball 的 sha256、大小、文件数。
4. **硬闸**：打完必须自查包里不含 `farm/state/`、`farm/profiles/`、任何 `*.db*`；命中就删包并 FAIL。

**验收（贴原文）**：

```bash
bash distribution/make-bundle.sh --out /tmp/bx
tar -tzf /tmp/bx/dsh-ecom-0.1.0.tar.gz | grep -E 'farm/(state|profiles)/|\.db' ; echo "grep-exit=$?"   # 期望 1（无命中）
rm -rf /tmp/bx-x && mkdir -p /tmp/bx-x && tar -xzf /tmp/bx/dsh-ecom-0.1.0.tar.gz -C /tmp/bx-x
cd /tmp/bx-x/dsh-ecom-0.1.0 && bash distribution/verify.sh     # 期望 PASS=63 FAIL=0 WARN=0 / READY
```

---

## T2 一键安装 `distribution/install-all.sh`

**要做的**：把三层 install 串起来，失败即停。

```bash
bash distribution/install-all.sh <目标目录>                    # 默认只装 amazon，另提示 --all-platforms
bash distribution/install-all.sh <目标目录> --all-platforms    # 7 个平台全装
bash distribution/install-all.sh <目标目录> --check            # 只校验，不写文件
```

要求：
- 顺序 L1 → L2 → L3（平台按 `l3/install.sh --list` 的真实清单），每步打印该步 PASS/FAIL，最后一行 `RESULT: READY` 或 `NOT_READY` 加汇总；
- 任一步失败立即停，打印失败的那条命令和原文，退出码非 0；
- 末尾提示下一条该跑什么（`bash distribution/verify.sh` 或 doctor）；
- 不重复实现安装逻辑，只调用现有 install.sh。

**验收**：`bash distribution/install-all.sh /tmp/trial-ws` 装完贴原文；`ls /tmp/trial-ws/.dsh` 能看到 L1 标记与 skills。

---

## T3 环境体检 `distribution/doctor.sh`

**要做的**：试装前先跑它，把环境问题一次说清。

检查项（每项一行 PASS/WARN/FAIL）：

1. OS / 架构（`uname -s -m`），Windows（MINGW/MSYS/CYGWIN）直接 FAIL 并指向 `docs/external-setup.md` §8；
2. `bash` 版本（3.2 可用，<3.2 FAIL）；
3. `node`（存在 + `node -v` 主版本 ≥18），不在 PATH 时提示 `/opt/homebrew/bin`；
4. `python3`（存在即可，版本只展示）；
5. `git`、`curl`、`tar` 是否可用；
6. 磁盘可用空间（当前目录 `<1G` WARN）；
7. 端口 `19671`/`19555` 是否已被占用（占用只 WARN，说明可能已有农场在跑）；
8. `GATEWAY_TOKEN` 或 `DSH_SECRET_GATEWAY_TOKEN`（只看长度，不打印值）：无 → WARN；有但 `<32` → WARN；
9. `farm/node_modules/ws` 是否存在（缺则 WARN 并给 `npm install` 提示）；
10. `~/.dsh/venvs/camoufox/bin/python` 是否存在（缺则 WARN，说明 camoufox 任务不可用）。

输出末尾 `RESULT: READY`（无 FAIL）或 `NOT_READY`（有 FAIL），退出码 0/1。

**验收**：本机跑一遍贴原文（应只有令牌与 camoufox 的 WARN/或全 PASS）。

---

## T4 试装包 `docs/trial-kit.md` + 入口

内容只要四块，全部基于你刚跑出来的真实命令：

1. **15 分钟试装**：拿 tarball → 解压 → `doctor.sh` → `install-all.sh` → `verify.sh`；
2. **环境要求表**（macOS arm64 基线；Windows 不支持，给 WSL2 一句话指向 §8）；
3. **回报模板**（复制就能填）：OS/arch、`node -v`、`python3 -V`、doctor 末尾、verify 末尾、失败原文、总耗时；
4. **常见故障**：只写你实际能复现的（至少包含：无 GATEWAY_TOKEN、node 不在 PATH、端口被占、令牌 <32 的 WARN 含义）。

同时在 `README.md` 快速开始节加一行指向 `docs/trial-kit.md`，并在 `docs/roadmap.md` 阶段 1 那行把「试装包已就绪」补上（数字用实测）。

**验收**：`docs/trial-kit.md` 里每条命令你都在本机原样跑过；文里出现的 PASS 数必须与实测一致。

---

## 回报格式

```
T1：make-bundle 末尾原文（大小/sha256/文件数）+ 包内 grep 原文 + 解压后 verify 末尾原文
T2：install-all 末尾原文 + ls 目标目录原文
T3：doctor 全文
T4：trial-kit 里出现的每个数字对应哪条命令
```

卡住就停在原地写清：哪一行、什么错、试过什么。
