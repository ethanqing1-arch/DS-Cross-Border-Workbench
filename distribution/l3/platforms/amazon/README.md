# Amazon 平台包（完整档）

装法：

```bash
bash install.sh amazon <已装 L2 的目标目录>            # 安装
bash install.sh amazon <已装 L2 的目标目录> --check    # 只校验
```

落点：`<目标目录>/95-engine/platforms/amazon/`。

## 这个包有什么

- 平台身份：`amazon` / tier `full`
- skill：`referenced` —— 声明 8 层 23 个（来源 `cbec-selection-master`），**内容不随包分发**，见 [skills/REFERENCES.md](skills/REFERENCES.md)
- 连接器声明：`amazon-spapi`（T1）、`seller-sprite` / `sorftime`（T2，可选）、`browser-farm`（T3）
- 参数覆盖：`overrides/platform.json` 里 6 个费率字段一律 `null` + `_note 待业务确认`

## 缺口

- 23 个 skill 只有声明没有内容，本机也没有源码；要跑 Amazon 专项口径得先把源码放本机并改 `skills.mode=bundled`。
- 费率/佣金全部待业务确认，框架不编数字。
- 连接器都只是声明，一个都没接。
