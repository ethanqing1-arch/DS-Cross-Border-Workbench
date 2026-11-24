# 交接单 16：图标定稿为候选 03

日期：2026-11-24
上游：交接单 15（提交 `0b8df20`）

## 用户已拍板

图标定 **03 错位交接**（`distribution/l1/branding/assets/candidates/03-shift-handoff.svg`）。

**「其他不改」的具体含义，按这个执行，不要自行扩大：**

- 图标图形本身不改：不加深色实心容器、不调比例、不改线条粗细、不改颜色
- 品牌配色不改：`brand.json` 的 `primary #0B5FFF` / `accent #F97316` / `surface #FFFFFF` / `ink #111827` 全部保持原值
- 名称、副标题、域名不动
- 不改任何布局或界面

**已知并接受的代价**：候选 03 是浅灰底、无实心容器，在浅色背景（Finder、Dock、favicon）上对比度偏低。用户已被告知并选择原样使用，不要再提这个建议，也不要偷偷加底色。

## T1 设为正式图标

1. 把 `distribution/l1/branding/assets/candidates/03-shift-handoff.svg` 的内容复制为 `distribution/l1/branding/assets/icon.svg`（覆盖原几何占位图）。
2. `brand.json` 的 `icon.placeholder` 改为 `false`；`icon.path` 保持 `assets/icon.svg` 不变；`icon.present` 保持 `true`。
3. `_notes` 更新：名称与图标均已定稿，配色仍为占位（配色这轮没定）。不许写「全部定稿」。

## T2 清理候选目录，但保留记录

- `distribution/l1/branding/assets/candidates/` 整个目录删掉（03 已是正式图标，01/02 不再有候选意义）。
- 01、02 的 SVG 移到 `docs/assets/branding-candidates/` 存档，文件名保持 `01-border-relay.svg`、`02-route-junction.svg`。
- `docs/assets/branding-candidates/` 里现有的 PNG 保留，不要删。
- `docs/branding-candidates.md` 更新：写明 03 已被采纳、01/02 存档在 `docs/assets/branding-candidates/`，并把表里 01/02 的 SVG 链接改到新路径。**不许删掉对 01/02 的记录**，那是决策依据。

## T3 回填因为去掉占位标记而变化的数字

`icon.placeholder` 从 `true` 变 `false` 后，`distribution/flow-smoke.sh` 里那条 `WARN 图标是占位，发布前替换` 会消失，WARN 总数会从 4 掉到 3。`distribution/l1/install.sh` 里同类 WARN 也会消失。

所以：

- 自己跑 `bash distribution/flow-smoke.sh`，把 `README.md` 与 `docs/roadmap.md` 里所有 `WARN=4` 改成本次实测值（预期 3）。
- `verify.sh` 的 PASS 数如果变了，一并回填。**数字一律以你自己跑出来的为准，不许照抄现有值。**
- 如果 `installer-selftest.sh` 或 `verify.sh` 里有断言依赖「图标是占位」这条 WARN，要一并调整，并在回报里说明你改了哪条。

## T4 更新品牌文档

`docs/branding.md`：把「图标占位」「发布前三步」里已完成的步骤改成完成态，写清楚当前还有 **配色** 是占位。不要写成全部定稿。

## 红线

1. 不碰 `farm/`、`~/.dsh`。
2. 不动 `docs/codex-dev-brief-*.md`。
3. 不动 `docs/proposals/` 下三份材料。
4. 不改品牌配色，不给图标加底色。
5. 不加任何兼容或迁移代码。

## 验证（你自己跑，原样贴输出）

```bash
bash distribution/l1/install.sh /tmp/kualang-icon-check --check
bash distribution/flow-smoke.sh
bash distribution/verify.sh
bash distribution/make-bundle.sh --out /tmp/b16 --dmg
ls -1 distribution/l1/branding/assets/
grep -n 'placeholder' distribution/l1/branding/brand.json
```

要求：

1. `install.sh --check` 的输出里**不再有**「图标是占位」的 WARN。
2. `flow-smoke.sh` 的 WARN 数是实测值（预期 3），并把 `WARN 图标是占位` 那条的消失作为证据贴出来。
3. `verify.sh` 全 PASS，PASS 数按实跑报。
4. `distribution/l1/branding/assets/` 下只剩 `icon.svg`（和 `.gitkeep`，如果有）。
5. `brand.json` 里 `icon.placeholder` 是 `false`，`icon.path` 仍是 `assets/icon.svg`。
6. DMG 卷标仍是「跨浪」，打包链路没断。

## 交付

- `git diff --check`
- 提交信息说明图标定稿为候选 03
- **不要推远端**
- 不要动 `docs/codex-dev-brief-15.md`、`-16.md` 本身（未跟踪，派单人自己提交）
