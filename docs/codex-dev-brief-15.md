# 交接单 15：图标候选、两个插件规格、skill 证据强度表、商标检索清单

日期：2026-11-24
上游：交接单 14（提交 `4bec07b`）

## 这单的性质

四件事都不改产品行为，只产材料。**核心约束：凡是需要法律判断或用户确认的地方，只出材料、不下结论。** 一个看着像结论但其实是编的答案，比没有答案更糟。

## T1 图标候选（3 个）

现状：`distribution/l1/branding/assets/icon.svg` 是几何占位图，`brand.json` 里 `icon.placeholder: true`。用户还没定稿图标。

产出 3 个候选 SVG，放 `distribution/l1/branding/assets/candidates/`，命名 `01-*.svg` / `02-*.svg` / `03-*.svg`：

- 必须 256×256，`viewBox="0 0 256 256"`，首字节 `<svg`
- 主题方向：**跨境 / 出海 / 数字员工**。用几何或抽象图形表达，不要写实，不要文字
- **禁止**：任何平台商标、任何接近 Amazon / eBay / TikTok / Shopee 等的图形暗示、任何「官方授权」暗示、任何字体嵌入
- 每个候选附一句设计说明（表达什么、为什么适合这个产品）
- 每个候选必须自证能渲染：用 `qlmanage -t` 或 `sips` 渲染成 PNG，确认不是坏 SVG，并报告三档尺寸（256 / 128 / 32）下是否还看得清
- **不要改 `brand.json` 的 `icon` 指向，不要改 `icon.placeholder`**。选哪个由用户定，这单只递材料

## T2 两个插件的规格草案（不实现）

`distribution/l1/plugins/manifest.json` 里 `retrace`、`rollback-withdraw` 现在是 `missing-source`，本机确实没有源码（`ls ~/.dsh/plugins` 无这两项）。

产出两份规格文档：`docs/proposals/retrace.md`、`docs/proposals/rollback-withdraw.md`。每份包含：

1. 这个插件解决什么问题（从名字合理推断，**明确标注这是推断，需要用户确认**）
2. 触发方式（谁调用、何时触发）
3. 输入 / 输出
4. 最小接口（函数签名或命令形式）
5. 权限边界（能读什么、能写什么、绝不能做什么）
6. 自检方式（怎么证明它工作，怎么写测试）
7. **实现前的待确认项**（必须列出所有需要用户拍板的地方）

**只写规格，不写实现代码。** 没有用户确认的功能定义，写出来也是猜的。

## T3 23 个 amazon skill 的来源证据强度表

现状：`docs/amazon-skill-licenses.md` 已有核查表，23 个 skill 全部「SKILL.md 里无许可字段」。

这单补的是**证据强度**：对每个 skill 目录查 git 历史，列出：

- 首次进入本仓库的提交号与日期
- 那次提交是否显示它是从别的路径搬入的（如 `cbec-selection-master/skills/...`）
- 目录内除 SKILL.md 外有没有任何作者、来源、许可线索

然后给一个三档判定：

- `明确出处`：有可追溯到作者或来源的记录
- `只能追到本仓某次提交`：只知道它哪次进来，不知道从哪来
- `完全无迹`：连提交都对不上

**不许下法律结论**，不许写「可对外分发」或「不可对外分发」。只列事实和档位。用户要的是看清自己手上有什么，不是一份免责声明。

## T4 商标检索清单（只出清单，不下结论）

产出 `docs/proposals/trademark-checklist.md`，包含：

- 待查名称：`跨浪`、`Kualang`、`getkualang.com`
- 待查类别：第 9 类（计算机软件）、第 35 类（广告/销售）、第 42 类（技术服务），以及为什么是这三类
- 已知同名实体清单（这些是派单人已核实的，直接引用，不要重新搜）：
  - 聊城跨浪跨境电子商务有限公司（跨境电商）
  - 莆田市秀屿区万象跨浪跨境电子商务行（跨境电商）
  - 跨浪（江西）电子商务有限公司（电商）
  - 西安跨浪科技有限公司（智能运动器械，20 项专利）
  - 山东跨浪文化传媒科技有限公司（视频内容）
  - 上海跨浪贸易有限公司（2017）
  - 鹰潭跨浪贸易有限公司（2025）
- 检索路径说明：中国商标网官方检索、以及需要人工判断的环节

**不许写任何「可注册」「不可注册」「注册成功率」的判断。** 你手上没有官方检索结果，写出来就是编。清单的用途是让人拿着去检索，不是替代检索。

## 红线

1. 不碰 `farm/`、不碰 `~/.dsh`（只读判断许可除外，延续现有做法）。
2. 不改 `brand.json` 的 `icon` 与 `icon.placeholder`。
3. 不改任何现有 skill 的 SKILL.md。
4. 不动 `docs/codex-dev-brief-*.md`。
5. `bash distribution/verify.sh` 必须仍是 `PASS=69 FAIL=0 WARN=0`——这单只加文件，不该影响验收。如果数字变了，说明你动了不该动的东西，自己查。

## 验证（你自己跑，原样贴输出）

```bash
bash distribution/verify.sh
ls -1 distribution/l1/branding/assets/candidates/
# 每个候选的渲染自检
for f in distribution/l1/branding/assets/candidates/*.svg; do
  echo "--- $f"; head -c 80 "$f"; echo
done
wc -l docs/proposals/*.md docs/amazon-skill-licenses.md
```

要求：

1. `verify.sh` 仍是 `PASS=69 FAIL=0 WARN=0`。
2. 3 个候选 SVG 都渲染成功，报告三档尺寸的辨识度判断。
3. 两份规格文档都包含「实现前的待确认项」一节。
4. 证据强度表覆盖全部 23 个 skill，三档里各有多少个要报数。
5. 商标清单里没有任何可注册性判断——你自查一遍，有这个字眼就删。

## 交付

- `git diff --check`
- 提交信息说明这单只产材料
- **不要推远端**
- 不要动 `docs/codex-dev-brief-15.md` 本身（未跟踪，派单人自己提交）
