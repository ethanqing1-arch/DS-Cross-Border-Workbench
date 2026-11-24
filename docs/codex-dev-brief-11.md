# Codex 交接单 11：阶段 3 的五项（机制写全，人定项留白）

## 背景（现状是我核过的）

阶段 3 五项里，**有的能写代码，有的必须人定**。这单的原则：**机制、校验、文档全部写死并自检；品牌名、真实授权结论、第三方插件源码不许编**。

现状证据：

- `distribution/l1/branding/brand.json`：名称 `Cross-Border Workbench`、配色已填，但 `_notes` 自述「全部为占位」；`icon.present=false`，`assets/` 只有 `.gitkeep`。
- 授权校验：仓库里零代码（`grep` 不到 licence 相关实现）。
- 三件插件：本机 `~/.dsh/plugins/` 只有 `dsh-prompt-enhancer`（含 `LICENSE`、`package.json`）；`retrace`、`rollback-withdraw` **本机没有源码**；仓库里三者的痕迹只在 docs。
- amazon skills 23 个，每个 `SKILL.md` 有 `name/description/layer/version`，**没有任何许可或来源字段**。
- `distribution/make-bundle.sh` 只产 `.tar.gz`（python tarfile），没有 zip/dmg/首次启动脚本；本机 `hdiutil`、`zip`、`unzip` 都在 `/usr/bin`。
- 验收基线：`verify.sh` 现在 `PASS=66`，`flow-smoke.sh` `PASS=8`，L1 默认安装 `write=1 skip=0 fail=0`。

## 硬约束（必读）

- 不碰 `farm/`、台账、profiles、正在跑的服务；不碰 DS Bot/DSH 自身与系统设置。
- `~/.dsh/plugins/` **只读**（可以读 LICENSE/package.json 判断可否随包，不许改、不许往里写）。
- **品牌名不许改**：保持 `Cross-Border Workbench`，标为占位待定稿；**不许用任何平台商标**（Amazon/eBay/TikTok 等）做图标或配色暗示。
- **私钥不许进仓库**：授权校验的私钥只能出现在自检的临时目录里或用户自己指定的仓库外路径。
- **第三方插件源码不许拷进仓库**，除非其 LICENSE 明确允许再分发且随包保留 LICENSE；不确定就只记录「缺源/待确认」。
- 授权默认**不启用**：`install.sh` 不加 `--require-licence` 时行为与现在完全一致，`write=1 skip=0 fail=0` 不许变。
- 零依赖：python 只用标准库、兼容 3.9.6；shell 用 bash 3.2 兼容写法（变量后接中文要 `${var}`）。
- 拿不准就停，写清卡点；**不许伪造数字**，也不许替用户下「这 23 个 skill 归谁」的结论。
- 只新增/修改：`distribution/l1/` 下相关文件、`distribution/l1/plugins/`、`distribution/l1/licence/`、`distribution/installer/`、`distribution/installer-selftest.sh`、`distribution/licence-selftest.sh`、`distribution/make-bundle.sh`、`distribution/verify.sh`、`docs/branding.md`、`docs/plugins.md`、`docs/licence.md`、`docs/amazon-skill-licenses.md`、`docs/roadmap.md`、`README.md`。
- 改完自己 commit，只提交你改/加的文件。

---

## T1 授权校验 `distribution/l1/licence/`

离线校验，RSA-2048 + SHA-256，用系统 `openssl`（本机 `/usr/bin/openssl`）。

- `verify.py`（标准库 + subprocess 调 openssl）：读 `licence.json`、公钥、机器码，校验签名与绑定、过期。
  - `licence.json` 字段：`{"licensee","tier","machine_id","issued_at","expires_at","sig"}`；`sig` 是 base64。
  - 签名对象：除 `sig` 外字段的规范化 JSON（`sort_keys=True, separators=(",",":")`，UTF-8）。
  - 机器码：macOS 取 `ioreg -rd1 -c IOPlatformExpertDevice` 的 `IOPlatformUUID`；Linux 取 `/etc/machine-id`；取不到 → `E_LICENCE_MACHINE`（退出码 3）。
  - 校验通过 → 0；签名错/篡改 → 4；机器码不符 → 5；过期 → 6；缺文件/缺公钥 → 2。
- `keygen.sh`：生成密钥对，私钥写到参数指定路径（默认 `~/dsh-ecom-licence/private.pem`，`chmod 600`），公钥打印出来供贴进 `public.pem`；**默认不覆盖已有私钥**。
- `distribution/l1/licence/public.pem`：放一个明显的 **PLACEHOLDER** 公钥（自检生成的也行，但文件头注释写明「占位，发布前替换为你的公钥」）。
- `install.sh`：新增 `--licence <path>` 与 `--require-licence`；只有带 `--require-licence` 才校验并拦截，默认完全不变。

自检 `distribution/licence-selftest.sh`（全在 mktemp 里，用临时密钥对）：

1. 合法 licence → 0；
2. 改一个字节 → 4（签名失败）；
3. 换一台机器码 → 5；
4. 过期 → 6；
5. 不带 `--require-licence` 时不校验（安装照常成功）；
6. 临时私钥/公钥不落在仓库内（`git status --porcelain` 前后为空）。

---

## T2 品牌化 `distribution/l1/branding/`

- 生成 `assets/icon.svg`：几何占位图形（不许含任何平台商标、不许仿造），256×256，纯 SVG。
- `brand.json`：`icon.present=true`，加 `"icon": {"path": ..., "present": true, "placeholder": true}`；`name` 保持 `Cross-Border Workbench`，加 `"name_status": "placeholder"`；`_notes` 保留「上线前须过商标检查」。
- `install.sh` 现有校验加两条：icon 文件存在且 `<svg` 开头；`placeholder` 为 true 时打一条 WARN「图标是占位，发布前替换」。
- `docs/branding.md`：怎么换名/换色/换图标（只改 brand.json + assets/）、图标规格（SVG，256×256，勿用平台商标）、商标检查清单、发布前必须做哪三步。

---

## T3 三件插件机制 `distribution/l1/plugins/`

不拷第三方代码，只把「装/校验/缺口」做成机制：

- `manifest.json`：三条 `{id, name, required, status, note, source_hint}`。`status` 允许 `ready` / `missing-source` / `license-unclear`。
  - `prompt-enhancer`：读 `~/.dsh/plugins/dsh-prompt-enhancer/LICENSE` 与 `package.json` 判定；许可允许再分发才标 `ready` 并说明来源路径，否则 `license-unclear`。
  - `retrace`、`rollback-withdraw`：本机无源 → `missing-source`，`source_hint` 写明需要用户提供什么（插件包目录或仓库地址）。
- `bundle/` 只放 `.gitkeep`（本单不随包任何插件）。
- `install.sh`：扫描 `bundle/` 下每个子目录 → 复制到 `$TARGET/.dsh/plugins/<id>`；缺的按 manifest 打 WARN（`插件缺源：<id>`），**FAIL 数为 0、默认写入数仍为 1**。
- `docs/plugins.md`：三件各自的作用、来源要求、许可检查步骤、放进 `bundle/` 后重跑什么。
- 机制自检放在 `installer-selftest.sh` 里：**复制一份 `distribution/l1` 到 mktemp**，加一个假插件目录，跑 install，断言插件被复制且 manifest 缺源项打 WARN。

---

## T4 安装包与首次启动 `distribution/installer/` + `make-bundle.sh`

- `make-bundle.sh` 增加：
  - 默认多产一个 `<name>-<ver>.zip`（内容与 tar.gz 相同，目录结构一致，含 `MANIFEST.sha256`）；
  - `--dmg` 时用 `hdiutil` 产 `.dmg`，内含 zip、`FIRST-RUN.md`、`install.command`；无 hdiutil 时 WARN 跳过，不改返回码。
- `distribution/installer/first-run.command`：双击可跑，依次 doctor → install-all → verify，最后打印「下一步做什么」；全程不写真实工作区（用 `~/ds-bot-workspace` 之外的目标，或用 `--target` 参数，默认 `~/dsh-ecom-workspace`），不碰 DS Bot 状态。
- `distribution/installer/FIRST-RUN.md`：五步、每步期望输出、失败怎么读。
- `installer-selftest.sh`（进 verify）：
  1. `bash -n` 检查 `first-run.command`；
  2. mktemp 里 `make-bundle.sh --out <tmp>` 产 tar.gz + zip，两者 `MANIFEST.sha256` 都可 `shasum -c`；
  3. 解 zip 后 `distribution/verify.sh` 的入口文件齐全（只查文件存在，不跑全套）；
  4. 有 hdiutil 则 `--dmg` 产物 `hdiutil imageinfo` 可读，无则 WARN；
  5. 插件机制断言（见 T3）。
  输出沿用 `PASS/FAIL` + `== 汇总 ==` + `RESULT: READY`。

---

## T5 23 skill 授权归属核查 `docs/amazon-skill-licenses.md`

只记录事实，不下结论：

- 表格 23 行：`skill 名 | layer | version | SKILL.md 里有无许可字段 | 仓库内可查的来源线索 | 需要用户确认什么`。
- 汇总：当前 0 个 skill 声明许可；23 个都需要「自研 / 购买 / 平台授权」之一的书面确认。
- 明确写：**未确认前，L3 amazon 包不对外分发**；技术侧只能做到「把来源列清楚」。

---

## T6 数字回填

- `distribution/verify.sh` 加两条聚合断言（licence-selftest、installer-selftest）→ `PASS=66 → 68`。
- `docs/roadmap.md:16` 与 `:132` 改为 `PASS=68`；`:19` 的「卖」行补一句「授权校验与安装包已就绪（默认不启用 licence）」。

---

## 验收（贴原文）

```bash
bash distribution/licence-selftest.sh          # PASS=n FAIL=0 / READY
bash distribution/installer-selftest.sh        # PASS=n FAIL=0 / READY
bash distribution/verify.sh                    # PASS=68 FAIL=0 WARN=0 / READY
bash distribution/flow-smoke.sh                # PASS=8（回归）
bash distribution/make-bundle.sh --out /tmp/b11 --dmg   # tar.gz + zip + dmg，含 SHA256
bash distribution/l1/install.sh /tmp/l1-ws     # 默认仍是 write=1 skip=0 fail=0
rm -rf /tmp/b11 /tmp/l1-ws
```

**必须额外证明的两件事**：

- 把 `--require-licence` 打开、给错误机器码 → 安装被拦（退出码非 0，错误码 `E_LICENCE_MACHINE`）。
- `make-bundle.sh` 产物里**不含** `~/.dsh`、私钥、`farm/state`、`profiles/`。

---

## 回报格式

```
T1：licence-selftest 末尾原文 + 6 条断言各自的退出码
T2：icon.svg 尺寸/前 80 字节 + install 的 WARN 行 + branding.md 改动行
T3：~/.dsh/plugins/dsh-prompt-enhancer/LICENSE 首行 + manifest 三条 status + 插件复制断言原文
T4：make-bundle --dmg 的三行产物（名称/字节/SHA256）+ installer-selftest 末尾原文
T5：23 行表格前 5 行 + 「未声明许可」计数
T6：verify 末尾 + roadmap 改动行
```

卡住就停在原地写清：哪一行、什么错、试过什么。
