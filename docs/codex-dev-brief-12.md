# 交接单 12：品牌名定稿「跨浪」+ 修两处验收漂移

日期：2026-11-24
上游：交接单 11（提交 `0a91822`）

## 背景与已核实事实

以下每条都是派单人逐条跑命令核对过的，不要凭印象推翻：

- 用户已定稿品牌名：中文 **跨浪**，英文/罗马字 **Kualang**，域名 **getkualang.com**。`kualang.com/.cn/.ai/.io/.co/.com.cn/.shop/.store` 全部已被他人占用，`getkualang.com` 是唯一可用的。
- 展示品牌名目前**硬编码在三处**：`distribution/l1/branding/brand.json:3`、`distribution/installer/FIRST-RUN.md:1`、`distribution/make-bundle.sh:129`。
- `docs/branding.md:3` 写着「品牌定稿时只改 brand.json 和 assets/」，与上面三处硬编码**自相矛盾**。
- `docs/roadmap.md:17` 与 `:141` 仍写 `flow-smoke → WARN=0`，而 `README.md:49` 已写 `WARN=4`，同一件事两个数。
- `distribution/l2/install.sh:142` 在缺 node 时打印 `WARN 缺 node，跳过 manifest 校验` 并**跳过校验**。l2 是 `l1/install.sh:22`、`l3/install.sh:23`、`verify.sh:20`、`doctor.sh:41` 之外**唯一**没有 `/opt/homebrew/bin` 兜底的脚本。实测 `env PATH=/usr/bin:/bin bash distribution/flow-smoke.sh` 因此多出第 5 条 WARN，且脚本仍然报 `RESULT: READY`。

## 红线

1. **技术 id 一律不动**：`dsh-ecom`、包名 `dsh-ecom-<version>`、`brand.json` 的 `id`、安装标记 `ecom-l1.json`、各 `manifest.json` 里的 name 全部保持原样。只改**展示名**。
2. 不碰 `farm/`、不碰 `docs/codex-dev-brief-1*.md`（历史交接单里的旧名是事实记录，不改）、不碰 `.git`。
3. 不引入任何第三方资产。图标继续用现有几何占位 SVG，`icon.placeholder` 保持 `true`（图标没定稿）。
4. 私钥不进程仓库。
5. **不要替我写文案**：`subtitle` 保持原值 `Amazon-first cross-border e-commerce workspace`，不要改。

## T1 品牌名定稿（`distribution/l1/branding/brand.json`）

- `"name"` → `"跨浪"`
- 新增 `"name_en": "Kualang"`
- 新增 `"domain": "getkualang.com"`
- `"name_status"` → `"final"`（按 `docs/branding.md:5` 的约定）
- `_notes` 第一条现在是「全部为占位：名称、副标题、配色、图标都还没定稿」→ 改成名称已定稿，配色与图标仍是占位。

`l1/install.sh` 的品牌校验只检查 `id/name/colors/icon`，新增字段不会破坏它，但你必须复跑验收证明（见 T5）。

## T2 消除品牌名硬编码

- `distribution/make-bundle.sh:129` 的 `-volname "Cross-Border Workbench"` 改为**从 `distribution/l1/branding/brand.json` 读 `name` 字段**，不要把「跨浪」也写死。目的是以后换名只改一个文件。
- `distribution/installer/FIRST-RUN.md:1` 标题改为 `# 跨浪 首次启动`。
- `docs/branding.md:3` 那句「只改 brand.json 和 assets/」改成准确表述：列出换名实际要动的文件（`brand.json`、`assets/`、`installer/FIRST-RUN.md` 标题），并说明 `make-bundle.sh` 已改为读 `brand.json`。

## T3 修 roadmap 两处数字漂移

`docs/roadmap.md:17` 与 `:141`：把 `WARN=0` 改成**你自己实测跑出来的数字**，括号说明改成与 `README.md:49` 一致的成因（图标占位 + 三件插件缺源）。**不许照抄 README 的数字**——必须先跑再写。若 `README.md:49` 与实测也不符，一并改。

## T4 修 l2 的 node 兜底

`distribution/l2/install.sh`：在 `set -uo pipefail` 之后，加与 `l1/install.sh:22`、`l3/install.sh:23` 同形的一行：

```bash
command -v node >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:$PATH"
```

**保留** `:142` 的 `WARN 缺 node，跳过 manifest 校验` 分支——真没装 node 的机器仍然要 WARN。只是这段逻辑现在能走到兜底后的 node。**不要**把这条 WARN 改成 FAIL。

## T5 验证（你自己跑，原样贴输出，不要改写）

```bash
env PATH=/usr/bin:/bin bash distribution/flow-smoke.sh
bash distribution/flow-smoke.sh
bash distribution/verify.sh
bash distribution/make-bundle.sh --out /tmp/b12 --dmg
hdiutil imageinfo /tmp/b12/dsh-ecom-0.1.0.dmg | head -20
env PATH=/usr/bin:/bin bash distribution/l2/install.sh /tmp/b12-l2-check --check
```

硬性要求：

1. `env PATH=/usr/bin:/bin` 下 flow-smoke **不再出现「缺 node」**，WARN 数为 4；普通环境下也必须是 4。
2. 上面最后一条 l2 `--check` 的输出里必须出现 `PASS manifest 可解析`，不能再是「跳过」。
3. `verify.sh` 全 PASS，PASS 数按实跑报。
4. DMG 卷标是「跨浪」，`hdiutil imageinfo` 可读。
5. 如果你给 `distribution/installer-selftest.sh` 补「DMG 卷标 == brand.json 的 name」断言（建议补），PASS 数会变，把新数字一起回填 `docs/roadmap.md` 与 `README.md`。
6. `grep -rn "Cross-Border Workbench"` 除 `docs/codex-dev-brief-1*.md` 外应为 0 命中。

## 交付

- 提交前跑 `git diff --check`。
- 提交信息说明改了哪几件事。
- **不要推远端。**
- 不要动 `docs/codex-dev-brief-11.md` 和本文件（未跟踪，派单人自己处理）。
