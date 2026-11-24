# L1 插件来源与随包安装

当前插件包目录为 `distribution/l1/plugins/bundle/`。安装器只读取这个目录中的插件，将各子目录复制到目标工作区的 `.dsh/plugins/<id>`。本机 `~/.dsh/plugins/` 仅用于来源核查。阶段 3 的三项功能记录在 [产品化方案](dsh-ecom-productization-plan.md) 中。

| ID | 作用 | 已核查的来源 |
|---|---|---|
| `prompt-enhancer` | 输入框一键优化提示词 | 本机 `~/.dsh/plugins/dsh-prompt-enhancer` 的 `package.json` 为 1.2.2，声明 MIT，`LICENSE` 允许再分发并要求保留版权和许可声明。现有版权行写的是 `Copyright (c) 2026 USERNAME`，入包前应向提供方核对原始版权声明。 |
| `retrace` | 回溯、编辑重发和重新生成 | 本机缺源。请提供插件包目录或上游仓库地址和对应版本。 |
| `rollback-withdraw` | Trae 式消息撤销和回滚 | 本机缺源。请提供插件包目录或上游仓库地址和对应版本。 |

1. 确认待入包版本的 `package.json`、`LICENSE` 和来源路径相互对应，核对插件及随附依赖的再分发条件。把证据及版本记入 `distribution/l1/plugins/manifest.json`。
2. 确认允许再分发后，将完整插件目录和原始许可证放在 `bundle/<id>/`，将该项标为 `ready`。缺少源码时标 `missing-source`，许可待核实时标 `license-unclear`。
3. 在临时目标重跑 `bash distribution/l1/install.sh <临时目标>`、`bash distribution/installer-selftest.sh` 和 `bash distribution/verify.sh`，确认插件落点、缺源提示和安装计数，再重打包。

`required` 记录产品所需插件。待入包目录缺失时，L1 打印 `WARN 插件缺源：<id>` 并继续。`--check` 仅查看。已有插件目录会保留，L1 的 `write/skip` 汇总计标记文件，插件结果逐项输出。
