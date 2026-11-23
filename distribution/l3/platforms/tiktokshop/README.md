# TikTok Shop 平台包（基线档）

装法：

```bash
bash install.sh tiktokshop <已装 L2 的目标目录>            # 安装
bash install.sh tiktokshop <已装 L2 的目标目录> --check    # 只校验
```

落点：`<目标目录>/95-engine/platforms/tiktokshop/`。

## 这个包有什么

- 平台身份：`tiktokshop` / tier `baseline`
- skill：`inherit-l2` —— 复用 L2 的 4 个业务 skill，不附专项 skill
- 连接器声明：`tiktok-shop-api`（T1，未接入）、`browser-farm`（T3，只读调研）
- 参数覆盖：6 个费率字段一律 `null` + `_note 待业务确认`，平台差异只写在 `_note` 里

## 缺口

- 没有 TikTok Shop 专项 skill，基线档能跑通用选品流程，跑不了平台专属口径。
- 费率/佣金全部待业务确认，框架不编数字。
- `tiktok-shop-api` 只是声明，没接授权。
