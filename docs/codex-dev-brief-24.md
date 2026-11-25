# brief-24：发行包两处安全缺口

这两条是我在验收 brief-23 时自己构造出来的，不是 Codex 自报的。

## 缺口一：`.pem` 私钥拦不住

`docs/release-checklist.md:18` 写的是「包内无任何私钥（包括 `*.pem` 私钥）」，但 `distribution/release.sh` 的 `check_path()` 只拦这些后缀：

```python
part.endswith((".key", ".p12", ".pfx", ".sqlite", ".sqlite3"))
```

`.pem` 完全不在名单里。也就是说，谁把一把 `private.pem` 放进仓库，它会被原样打进发行包，而且 `installer-selftest.sh` 第 8 条照样 PASS——**文档说拦，代码不拦**。

实测：现在包里确实有一个 `distribution/l1/licence/public.pem`，是公钥，应该留；正因为它存在，不能简单地把 `.pem` 全拦掉。

## 缺口二：包里带的是占位公钥

那个 `public.pem` 的内容是：

```
# PLACEHOLDER：占位，发布前替换为你的公钥。对应私钥已销毁。
```

占位公钥意味着**离线授权校验验不了任何真实签发的 licence**。现在 `release.sh` 对此一无所知，照样出包、照样 READY、照样 RESULT: READY。`docs/release-checklist.md` 也没把「替换公钥」列为阻断项——现在照着清单走，会发出一个授权功能不可用的包。

## 任务

### T1 收紧 `.pem` 规则

**文件**：`distribution/release.sh`

- `check_path()` 增加：任何 `*.pem` 一律拒绝，**白名单只有** `distribution/l1/licence/public.pem` 这一个路径；
- 再加一道内容检查：文件内容前几行出现 `BEGIN ... PRIVATE KEY` 的，无论后缀是什么都拒绝（防止私钥改名成 `.txt`）；
- 这两条检查要能被 `installer-selftest.sh` 和 `verify.sh` 复用（保持现有 `release.sh payload <dir>` 入口）。

### T2 占位公钥必须拦住发布

**文件**：`distribution/release.sh`、`docs/release-checklist.md`

- `release.sh` 在构建和核验时都读 `distribution/l1/licence/public.pem`：若首行含 `PLACEHOLDER` 或文件内没有 `BEGIN PUBLIC KEY`，
  - 默认 **拒绝出包**，退出码 `3`（与 `1` 脚本错误、`2` 参数错误区分开），输出写明「占位公钥，不能对外发布」；
  - 新增 `--allow-placeholder-licence`：显式允许内部试装，此时照常出包，但必须在产物核验输出里显著打印一行 `WARN 本包仅供内部试装：含占位授权公钥`。
- `docs/release-checklist.md` 的「构建前」增加阻断项：「`distribution/l1/licence/public.pem` 已替换为真实公钥（不含 `PLACEHOLDER`、含 `BEGIN PUBLIC KEY`）。未替换前只能带 `--allow-placeholder-licence` 出内部试装包」。
- `docs/release-checklist.md` 的「检查产物」把 `.pem` 那半句改成与代码一致的表述。

### T3 断言

**`distribution/installer-selftest.sh`** 增加：
1. 临时塞一个 `evil.pem`（内容无关）进源码副本 → `release.sh payload` 必须拒绝；
2. 临时塞一个 `notes.txt`、内容含 `BEGIN RSA PRIVATE KEY` → 必须拒绝；
3. 正常的 `public.pem`（白名单路径）→ 必须通过。

**`distribution/verify.sh`** 的 `7h` 增加：
1. 当前仓库是占位公钥时，`release.sh`（不带开关）退出码为 `3`，输出含「占位公钥」；
2. 带 `--allow-placeholder-licence` 时退出码 `0`，且输出含「仅供内部试装」；
3. 用真实公钥（`licence-selftest.sh` 里那套 keygen 生成的）时不需要开关就能通过。

第 3 条用 `licence-selftest.sh` 现成的 keygen 逻辑造一对临时密钥，**不要**往仓库里写任何私钥。

### T4 变异测试（写进收尾）

- 把 `.pem` 白名单判断去掉（改成全拒或全放）→ T3 第 1、3 条必须 FAIL；
- 把占位公钥检查去掉 → `7h` 第 1 条必须 FAIL。

## 范围与红线

- **只许改**：`distribution/release.sh`、`distribution/installer-selftest.sh`、`distribution/verify.sh`、`docs/release-checklist.md`、本交接单「收尾」。
- **不许改**：`make-bundle.sh`、`first-run.command`、任何 `scripts/*.py`、`licence/` 目录下的密钥文件。
- **红线**：
  - 绝不许往仓库里写入任何私钥（包括临时生成的）；
  - 白名单只能有一个路径，不许写成「`public*.pem` 通配」；
  - 退出码语义写死：`1` 脚本错误、`2` 参数错误、`3` 拒绝发布；
  - 现有 `--check` 和 `--out` 行为不许变。
- **不要 commit、不要 push**，改完停在干净工作区等我验收。

## 收尾

把下面原文追加到本文件末尾：

1. `bash distribution/verify.sh` 汇总行 + `7h` 新增三条原文；
2. `bash distribution/installer-selftest.sh` 汇总行 + 新增三条原文；
3. 当前仓库（占位公钥）跑 `release.sh` 的完整输出与退出码；
4. 两次变异测试原文；
5. `git status` 证明仓库里没有新增私钥文件。
