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

### 验收原文

`bash distribution/verify.sh` 退出码 `0`。

```text
  WARN 跳过 Amazon 真实样本需求侧断言（本轮未能取到可用样本，见 docs/amazon-throttle.md）
  PASS 7h.5 默认拒绝使用占位公钥构建（退出码 3）
  PASS 7h.6 显式允许内部试装并警告（退出码 0），默认核验拒绝占位包（退出码 3）
  PASS 7h.7 临时生成的真实公钥无需开关即可构建（退出码 0）
== 汇总: PASS=96 FAIL=0 WARN=1 ==
RESULT: READY
```

`bash distribution/installer-selftest.sh` 退出码 `0`。

```text
  PASS 9. 拒绝白名单外的 evil.pem（退出码 3）
  PASS 10. 拒绝含私钥标记的 notes.txt（退出码 3）
  PASS 11. 放行 distribution/l1/licence/public.pem（退出码 0）
== 汇总: PASS=11 FAIL=0 ==
RESULT: READY
```

当前仓库运行 `bash distribution/release.sh`，退出码 `3`。完整输出如下。

```text
FAIL 占位公钥，不能对外发布
```

### 两次变异测试

变异仅在仓库外的解包副本上执行。

第一次移除 `.pem` 精确路径白名单，验证全放行和全拒绝两种结果。

全放行时 `bash distribution/installer-selftest.sh` 退出码 `1`。

```text
  FAIL 9. 拒绝白名单外的 evil.pem（退出码 0，期望 3）
  PASS 10. 拒绝含私钥标记的 notes.txt（退出码 3）
  PASS 11. 放行 distribution/l1/licence/public.pem（退出码 0）
== 汇总: PASS=10 FAIL=1 ==
RESULT: NOT_READY
```

全拒绝时 `bash distribution/installer-selftest.sh` 退出码 `1`。

```text
FAIL 发行包含禁止路径：distribution/l1/licence/public.pem
  FAIL 9. 拒绝白名单外的 evil.pem（退出码 3，期望 3）
FAIL 发行包含禁止路径：distribution/l1/licence/public.pem
  FAIL 10. 拒绝含私钥标记的 notes.txt（退出码 3，期望 3）
FAIL 发行包含禁止路径：distribution/l1/licence/public.pem
FAIL 发行包含禁止路径：distribution/l1/licence/public.pem
  FAIL 11. 未放行 distribution/l1/licence/public.pem
== 汇总: PASS=7 FAIL=4 ==
RESULT: NOT_READY
```

第二次禁用占位公钥拦截。`bash distribution/verify.sh` 退出码 `1`。

```text
  FAIL 7h.5 默认拒绝使用占位公钥构建（退出码 0，期望 3）
  FAIL 7h.6 内部试装或占位包核验结果异常（构建退出码 0，核验退出码 0）
  PASS 7h.7 临时生成的真实公钥无需开关即可构建（退出码 0）
== 汇总: PASS=93 FAIL=2 WARN=1 ==
RESULT: NOT_READY
```

### 补充验收

`bash distribution/flow-smoke.sh` 退出码 `0`。

```text
  WARN 插件缺源：prompt-enhancer
  WARN 插件缺源：retrace
  WARN 插件缺源：rollback-withdraw
== 汇总: PASS=9 FAIL=0 WARN=3 ==
RESULT: READY
```

无公钥头的副本默认构建和默认核验均退出 `3`。显式允许后，ZIP、tar.gz 和 DMG 可构建，ZIP 核验打印内部试装警告。核验前后的产物 inode、mtime 和 SHA256 一致。无效参数退出 `2`，核验不存在的 ZIP 退出 `1`。

### Git 工作区

`git status --porcelain=v1 --untracked-files=all` 原文如下。

```text
 M distribution/installer-selftest.sh
 M distribution/release.sh
 M distribution/verify.sh
 M docs/codex-dev-brief-24.md
 M docs/release-checklist.md
```

五个范围内文件均为未暂存修改。仓库中未新增私钥或其他文件。

### 独立复跑补记

总验收、安装自检和业务流冒烟复跑结果与上文一致。默认发布退出 `3`，未创建 `distribution/out/`。

在另一个 `mktemp` 副本中复跑占位闸门变异，使用随包的农场路径占位变量和本机空端口。Git 状态检查按解包目录规则跳过，网关相关断言产生预期警告。原始输出如下，退出码为 `1`。

```text
  FAIL 7h.5 默认拒绝使用占位公钥构建（退出码 0，期望 3）
  FAIL 7h.6 内部试装或占位包核验结果异常（构建退出码 0，核验退出码 0）
== 汇总: PASS=92 FAIL=2 WARN=3 ==
RESULT: NOT_READY
```
