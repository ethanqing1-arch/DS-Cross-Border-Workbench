# Amazon 平台包（完整档）

装法：

```bash
bash install.sh amazon <已装 L2 的目标目录>            # 安装
bash install.sh amazon <已装 L2 的目标目录> --check    # 只校验
```

落点：`<目标目录>/95-engine/platforms/amazon/`。

## 这个包有什么

- 平台身份：`amazon` / tier `full`
- skill：`bundled`，随包安装 8 层 23 个 skill 及其附属文件，见 [skills/REFERENCES.md](skills/REFERENCES.md)
- 选品引擎：`engine/score.py`（四维打分 + 三层利润 + 硬红线），随包安装，见下节
- 写作规范：`SKILL_SPEC.md`，23 个 skill 的唯一事实源
- 连接器声明：`amazon-spapi`（T1）、`seller-sprite` / `sorftime`（T2，可选）、`browser-farm`（T3）
- 参数覆盖：`overrides/platform.json` 里 6 个费率字段一律 `null` + `_note 待业务确认`

## 引擎（选品打分）

装完在 `<目标目录>/95-engine/platforms/amazon/engine/`。`score.py` 只用标准库；
要出 Excel 才需要 `openpyxl`。

```bash
cd <目标目录>/95-engine/platforms/amazon
python3 engine/score.py --help          # 参数齐
python3 engine/score.py                 # 用 data 里的样例跑一遍
python3 engine/validate_skills.py       # 校验 23 个 skill 结构
python3 engine/selftest.py              # 128 项断言
```

`--input <csv> --top N --category <名>` 换自己的候选；列名照抄样例，
缺列会被默认值补齐并在输出 CSV 里标出。第一次跑之前要改的三个值见源仓 `INSTALL.md` 第六节
（`FX_DEFAULT`、候选 CSV、`RED_LINE`）——放宽红线是最常见的自欺，改之前先想清楚。

## 缺口

- 授权归属待定，对外分发前需确认。
- 费率/佣金全部待业务确认，框架不编数字。
- 连接器都只是声明，一个都没接。
