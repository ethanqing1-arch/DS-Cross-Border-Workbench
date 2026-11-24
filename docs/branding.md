# L1 品牌占位

`Cross-Border Workbench` 是当前占位名称。品牌定稿时只改 `distribution/l1/branding/brand.json` 和同目录的 `assets/`。

- 换名时更新 `name`、`subtitle`，确认定稿后将 `name_status` 改成 `final`。
- 换色时更新 `colors.primary`、`accent`、`surface`、`ink` 的十六进制色值，确认文字与背景的对比度。
- 换图标时把 SVG 放入 `assets/` 并更新 `icon.path`。保持 `icon.present=true`，图标获批后将 `icon.placeholder` 改为 `false`。SVG 首字节必须以 `<svg` 开始，设置 `width="256"`、`height="256"` 和 `viewBox="0 0 256 256"`。

## 商标检查清单

- 检索目标市场和相关类别的名称、近似拼写及图形，记录结果。
- 核对名称、图形和字体的来源与书面授权。平台商标、近似图形和暗示官方身份的配色不得用于品牌图标。
- 确认产品页和安装包上的名称、配色、图标一致，并保存品牌定稿和检查记录。

## 发布前的三步

1. 由发布负责人确认名称、图标和配色的商标检查结果。
2. 写入经确认的品牌文件，替换几何占位图并移除占位标记。
3. 用 `bash distribution/l1/install.sh <临时目标目录> --check` 验证，确认图标校验通过且占位警告消失，再重打安装包。
