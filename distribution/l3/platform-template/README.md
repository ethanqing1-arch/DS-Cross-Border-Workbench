# 平台包模板

新平台的复制骨架。四步：

1. `cp -R platform-template platforms/<id>`
2. 改 `manifest.json`：**`id` 必须等于目录名**；`name` / `tier` / `skills` / `connectors` 按实际填
3. 填 `overrides/platform.json`：费率/佣金没确认就保持 `"value": null` + `"_note": "待业务确认"`
4. 自检：`bash install.sh <id> <已装 L2 的目标目录> --check`

模板里的 `example` 是一个能通过 schema 校验的示例 id，所以「复制到 `platforms/example/` 再跑一遍」就是模板可用性的自证。

## 两个档位怎么选

| tier | 条件 | skills.mode |
|---|---|---|
| `full` | 有平台专项 skill + 可用数据源 | `bundled`（包内自带）或 `referenced`（有源但暂不分发） |
| `baseline` | 无平台专项 skill | `inherit-l2`（复用 L2 业务 skill，只换平台参数） |

## 不许做的事

- 不要编费率数字。没确认就 `null`，`_note` 写「待业务确认」。
- 不要在没有授权来源的情况下把第三方 skill 内容拷进 `skills/`。
- 不要改 `install.sh` 的落点（`95-engine/platforms/<id>/`），工作区 README 写死了目录职责。
