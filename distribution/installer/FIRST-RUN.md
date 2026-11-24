# 跨浪 首次启动

1. **打开安装包。** macOS 双击 `.dmg`，应看到 `install.command`、`FIRST-RUN.md` 和版本 ZIP。使用 ZIP 时解压后找到 `distribution/installer/first-run.command`。
2. **选择工作区并启动。** 双击对应的 `.command`，默认目标是 `~/kualang-workspace`。需要自选目录时，用 `bash <脚本路径> --target <独立工作区路径>`。终端应显示 `目标工作区`。DMG 里的 ZIP 会在目标目录的 `.workbench-releases/` 内校验并解压，保留该目录以供后续使用。
3. **看环境检查。** `== doctor ==` 应以 `RESULT: READY` 结束。看到 `FAIL` 时按该行补齐工具，重开脚本。`WARN` 标记网关、令牌等环境条件。
4. **看试装结果。** `== install-all ==` 应显示 `PASS L1`、`PASS L2`、`PASS L3 amazon` 和 `RESULT: READY`。图标占位及插件缺源为提示。若中途退出，从第一条 `FAIL` 和紧随的失败命令定位问题。
5. **看验收并开始试用。** `== verify ==` 应显示 `PASS=68 FAIL=0` 和 `RESULT: READY`，随后出现 `下一步做什么`。按终端提示打开目标目录，用随包样例试跑。遇到验收失败时保留从失败阶段标题到末尾的原文和退出码。
