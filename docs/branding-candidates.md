# 跨浪图标候选

三款均使用 256×256 的独立 SVG。下表中的 PNG 由 macOS `sips` 从对应 SVG 生成，逐张核对像素尺寸，并按实际显示尺寸检查主体和细节。图标由用户选定。

| 候选 SVG | 设计说明 | 256 px | 128 px | 32 px |
|---|---|---|---|---|
| [01 边界接力](../distribution/l1/branding/assets/candidates/01-border-relay.svg) | 两道几何边界中间是抽象人形，表达同一位数字员工在不同市场之间协调业务。 | [可辨](assets/branding-candidates/01-border-relay-256.png)，人形、边界及留白清楚 | [可辨](assets/branding-candidates/01-border-relay-128.png)，头部与肩部仍分开 | [可辨](assets/branding-candidates/01-border-relay-32.png)，两侧边界和人形均可一眼分清 |
| [02 航线交汇](../distribution/l1/branding/assets/candidates/02-route-junction.svg) | 四段折线在一个任务节点周围交汇，表达数字员工汇集来自不同市场的工作。 | [可辨](assets/branding-candidates/02-route-junction-256.png)，四段折线和中心圆清楚 | [可辨](assets/branding-candidates/02-route-junction-128.png)，方向和两色分区清楚 | [可辨](assets/branding-candidates/02-route-junction-32.png)，菱形轮廓、双色和中心圆仍清楚，折线分段主要靠颜色区分 |
| [03 错位交接](../distribution/l1/branding/assets/candidates/03-shift-handoff.svg) | 两枚错位直角包住几何机器人，表达数字员工在两个工作区域间接手任务。 | [可辨](assets/branding-candidates/03-shift-handoff-256.png)，直角、头部和双眼清楚 | [可辨](assets/branding-candidates/03-shift-handoff-128.png)，头部与直角之间的空隙清楚 | [可辨](assets/branding-candidates/03-shift-handoff-32.png)，直角与头部清楚，双眼缩成两个亮点 |

从仓库根目录复现渲染，以 01 的 32 px 预览为例。

```bash
sips -s format png -z 32 32 distribution/l1/branding/assets/candidates/01-border-relay.svg --out /tmp/01-border-relay-32.png
sips -g pixelWidth -g pixelHeight /tmp/01-border-relay-32.png
```
