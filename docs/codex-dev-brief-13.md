# 交接单 13：技术 id 全套改为 `kualang`

日期：2026-11-24
上游：交接单 12（提交 `9ab50c2`）

## 决策与已核实事实

- 用户拍板：技术 id 从 `dsh-ecom` 全套改为 **`kualang`**。旧的「技术 id 一律不动」红线作废。
- 影响面：`grep -rn "dsh-ecom" --exclude-dir=.git .` = **87 处命中，45 个文件**。
- **现在是改名的唯一安全窗口**，三条证据：
  - `ls -d ~/dsh-ecom-workspace` → 不存在，本机没有旧安装。
  - `ls ~/.dsh/plugins | grep -i ecom` → 空，没有装过旧插件。
  - DS Bot 侧 `list_capabilities` 只有 `browser-farm`，没有 `dsh-ecom` 的注册，不会留孤儿注册。
- 改名后本机不存在兼容负担，**不要写任何向后兼容/迁移代码**。

## 改名映射（一处都不能漏）

| 旧 | 新 | 位置 |
|---|---|---|
| `dsh-ecom`（id） | `kualang` | `distribution/l1/branding/brand.json:2` |
| `dsh-ecom-l1` | `kualang-l1` | `l1/manifest.json:2`、`verify.sh:74` |
| `dsh-ecom-cbec` | `kualang-cbec` | `l2/bundle/package.json:2`、7 个 `l3/platforms/*/manifest.json`、`l3/platform-template/manifest.json`、`l3/manifest.json`、`l3/schema/platform.schema.json:32,34`、`l3/install.sh:183,189` |
| `dsh-ecom-amazon` 等 7 个 | `kualang-amazon` 等 | `l3/platforms/*/bundle/package.json` |
| `ecom-l1.json`（安装标记） | `kualang-l1.json` | 所有写/读该标记的地方（`l1/install.sh`、`verify.sh`、`e2e-smoke.sh:158,172`、`installer-selftest.sh`、`first-run.command`） |
| `dsh-ecom-<version>` | `kualang-<version>` | `distribution/make-bundle.sh` 的 `top`、`distribution/installer-selftest.sh` 的 `top`、`first-run.command` 里的 ZIP 名正则 `r"dsh-ecom-[0-9]+\.[0-9]+\.[0-9]+"` |
| `~/dsh-ecom-workspace` | `~/kualang-workspace` | `first-run.command` 默认 target |
| `~/dsh-ecom-licence/` | `~/kualang-licence/` | `l1/licence/keygen.sh` 默认私钥路径 |
| `docs/dsh-ecom-productization-plan.md` | `docs/kualang-productization-plan.md` | 文件改名 + `l1/capability/browser-farm.json:12` 的 `_source` 引用 |
| 临时目录前缀 `dsh-ecom-*` | `kualang-*` | `flow-smoke.sh`、`verify.sh`、`licence-selftest.sh`、`installer-selftest.sh`、`e2e-smoke.sh` 的 mktemp |

其余文档里的文字引用同步改：`README.md`、`CONTRIBUTING.md`、`distribution/README.md`、`l2/README.md`、`l3/README.md`、`docs/branding.md`、`docs/licence.md`、`docs/plugins.md`、`docs/roadmap.md`、`docs/trial-kit.md`、`docs/amazon-skill-licenses.md`。

## 红线

1. **不许留半改状态。** 改完 `grep -rn "dsh-ecom" --exclude-dir=.git . | grep -v '^\./docs/codex-dev-brief-'` 必须是 0 命中。`grep -rn "ecom-l1"` 同理。
2. `docs/codex-dev-brief-*.md`（含 3、7、11、12）是历史事实记录，**不要改它们的内容**。本文件（13）除外。
3. `VERSION` 保持 `0.1.0`，不要顺手 bump。
4. 不碰 `farm/`、不碰 `~/.dsh`。
5. 安装包内容排除规则不变：不得含 `.dsh`、私钥、`farm/state`、`farm/profiles`。
6. DMG 卷标仍然从 `brand.json` 读 `name`，**不许把「跨浪」再写死一处**。
7. 不加向后兼容、不加迁移脚本、不保留旧 id 别名。

## 最容易踩的两个点

- `l3/install.sh:183,189` 的「L2 双证」判断依赖 L2 标记文件名。只改 L2 写的那头、不改 L3 读的那头，从零装 L3 会 FAIL。
- `first-run.command` 里用正则校验 ZIP 顶层目录名，改 `make-bundle.sh` 的 `top` 不同步改这个正则，DMG 里的 `install.command` 会直接报「发行 ZIP 文件名不符合版本约定」。

## 验证（你自己跑，原样贴输出，不要改写）

```bash
# 1. 从零完整装链（最关键的一条）
T=$(mktemp -d /tmp/kualang-flow.XXXXXX)
bash distribution/installer/first-run.command --target "$T"

# 2. 两个环境的冒烟
bash distribution/flow-smoke.sh
env PATH=/usr/bin:/bin bash distribution/flow-smoke.sh

# 3. 总装验收
bash distribution/verify.sh

# 4. 发行包
bash distribution/make-bundle.sh --out /tmp/b13 --dmg
hdiutil imageinfo /tmp/b13/kualang-0.1.0.dmg | head -5

# 5. 残留扫描（两条都必须是 0）
grep -rn "dsh-ecom" --exclude-dir=.git . | grep -v '^\./docs/codex-dev-brief-'
grep -rn "ecom-l1" --exclude-dir=.git . | grep -v '^\./docs/codex-dev-brief-'
```

硬性要求：

1. 第 1 条必须走到 `PASS=*` / `RESULT: READY`，证明改名后**从零装到验收全通**。
2. flow-smoke 两个环境都必须是 `PASS=8 FAIL=0 WARN=4`，剥 PATH 那个不许出现「缺 node」。
3. `verify.sh` 全 PASS，PASS 数按实跑报；和 68 不一样就说明白为什么。
4. 发行包文件名是 `kualang-0.1.0.tar.gz/.zip/.dmg`，DMG 卷标仍是「跨浪」。
5. 把 DMG 挂载后跑一次里面的 `install.command` 到全新临时目录，必须同样全通（这条证明打包链路没被改名切断）。
6. 残留扫描两条都是 0。
7. 文档里所有命令示例的产物文件名同步（改名后 `dsh-ecom-0.1.0.dmg` 已不存在）。

## 交付

- 提交前 `git diff --check`。
- 提交信息说明这是 id 改名并列出映射要点。
- **不要推远端。**
- 不要动 `docs/codex-dev-brief-11.md`、`-12.md` 和本文件（未跟踪，派单人自己提交）。
