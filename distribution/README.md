# distribution/ — 跨境电商版三层分发

这个目录是**交付层**，不是业务代码。装的时候按 **L1 → L2 → L3** 顺序，越往后越依赖前一层。

| 层 | 包 | 入口 | 落点 | 状态 |
|---|---|---|---|---|
| L1 核心 | `dsh-ecom-l1`（`l1/`）+ 农场 `browser-farm` | `l1/install.sh <目标目录>` + DS Bot 共享能力注册 | `<目标>/.dsh/ecom-l1.json` 标记；7 个 `farm_*` 工具进 DS Bot 工具表 | 已交付（M1 能力 + L1 包），注册与 Allow 仍是人工两步 |
| L2 版本包 | `dsh-ecom-cbec` | `l2/install.sh <目标目录>` | `<目标>/.dsh/skills/` + 工作区骨架 | 已交付（M2） |
| L3 平台包 | `dsh-ecom-platform-framework` | `l3/install.sh <平台> <目标目录>` | `<目标>/95-engine/platforms/<id>/` | 框架 + 7 个平台已交付（M3 / M4） |

L1 的农场代码在仓库根的 `farm/`（`farm/mcp/farm-mcp.js` 是那 7 个工具的 stdio 适配层）；`l1/` 放它的安装包——capability 载荷、品牌占位、安装器与种子剧本。装包只校验并写标记文件，**真正的注册与 Allow 在 DS Bot 里人工做**，脚本不代做。

## 安装顺序

```bash
# 1) L1：装包（校验 node / farm / 载荷 / 品牌，写 .dsh/ecom-l1.json 标记并打印注册步骤）
bash distribution/l1/install.sh ~/ds-bot-workspace

# 1b) L1 第二步（人工，脚本不代做）：起网关 → 注册 capability → 用户 Allow
cd farm && bash scripts/start-gateway.sh --daemon
#    注册参数见 distribution/l1/capability/browser-farm.json，
#    五步见 distribution/l1/SEED-L1.md

# 2) L2 安装工作区骨架、业务 skills 及其附属文件
bash distribution/l2/install.sh ~/ds-bot-workspace

# 3) L3：装平台（可多个，重复装是幂等的）
bash distribution/l3/install.sh amazon   ~/ds-bot-workspace
bash distribution/l3/install.sh ebay     ~/ds-bot-workspace
bash distribution/l3/install.sh --list   # 看全部 7 个

# 4) 播种：由 Main Bot 按 l2/SEED.md 建 11 个 bot、5 个群
```

三个安装器都是**非破坏**语义：已存在的文件跳过，`--force` 才覆盖，`--check` 只校验不写。

## 一条命令验收

```bash
bash distribution/verify.sh            # 跑完清掉临时目录
bash distribution/verify.sh --keep     # 保留临时目录看现场
```

它会在 `mktemp` 目录里依次跑：L1 安装 → L2 安装 → 7 个平台逐个安装 → 全量 `--check`（前后 shasum 对比）→ L1 负例（`--farm` 指空目录必须 FAIL 且目标 0 写入）→ 空目录装平台负例（必须 FAIL 且 0 写入）→ 真工作区 mtime 边界校验，最后打 `PASS/FAIL/WARN` 汇总、`RESULT: READY / NOT_READY` 与退出码（0 / 1）。

总验收依赖 `bash` 和 `node`。单独运行 L2 安装器时，PATH 中没有 node 会跳过 manifest 结构校验并继续安装。

## 当前真实 vs 占位

**真的（已验过）**

- L1：`l1/install.sh` 校验 node 绝对路径 / `farm/mcp/farm-mcp.js` 存在且语法过 / 载荷无明文 secret / 品牌占位 / 网关可达（只 WARN），写 `.dsh/ecom-l1.json` 标记，`--check` 幂等，`--farm` 空目录负例 FAIL 且 0 写入。
- L2 安装工作区文件和 `manifest.json` 所列业务 skills，保留 skill 附属文件的目录结构。包内另有 11 个 bot、5 个群的预设和 SEED 剧本。
- L3：schema + 可复制模板（`example` 可直接跑通）+ 安装器（前置双证、非破坏、`--check`、`--force`）。
- 7 个平台包都能装进已装 L2 的目录。Amazon 的工作区落点有 50 个文件，其余平台各有 4 个。重复装和 `--check` 都是 0 写入。
- L2 与 Amazon 各有独立的 DSH bundle。仓库脚本校验 skill 镜像，DS Bot 内的安装步骤见 [L3 平台包文档](l3/README.md#dsh-bundle)。

**占位（别误读成能直接卖）**

| 占位项 | 现状 |
|---|---|
| 费率/佣金 | 7 个平台的 6 个费率字段**全部 `null`** + `_note: 待业务确认`，一个数字都没填 |
| 官方 API | TikTok Shop / Shopee / Lazada / Walmart / AliExpress / eBay / Amazon 的连接器**全是声明，一个都没接授权** |
| Amazon 专项 skill 授权 | 23 个专项 skill 随包交付，对外分发授权待确认。见 [来源与授权](l3/platforms/amazon/skills/REFERENCES.md) |
| 基线平台 skill | eBay / TikTok Shop / Shopee / Lazada / Walmart / AliExpress 都是 `skills.mode=inherit-l2`，没有平台专项 skill |
| 数据源降级链 | 计划第 4 节的 `data_sources`（tier 优先级与降级）**没进 schema**，还没有消费方 |
| L1 的真注册 | `l1/install.sh` 只校验与写标记；`save_capability` 和 Allow 在 DS Bot 侧，脚本不代做，也不能代做 |

## 边界

- `install.sh` / `verify.sh` 只写**目标目录**和 `mktemp` 目录；不碰 DS Bot 应用状态、不碰 farm 台账与服务、不安装 bundle。
- `verify.sh` 默认不写 `~/ds-bot-workspace`（只读它的 mtime 做边界校验）；要真装进去得你显式把那个路径当目标传。
- 不跑 `plugin_manager install`，不碰 launchd。

## 已知缺口（按影响排序）

1. 费率全 `null`，定价前必须由业务补实值，框架不编数字。
2. 7 个平台的官方 API 都未接入，`browser-farm` 也只声明「只读调研，绝不做登录态店铺操作」。
3. L2 版本判不了：L2 的 `install.sh` 不把 `manifest.json` 落到目标目录，`requires.dsh-ecom-cbec>=0.1.0` 只能靠双证存在判。
4. schema 没有 ajv 级校验，`l3/install.sh` 里是内置子集校验器。
5. `verify.sh` 只能验本仓库的安装与载荷文件；DS Bot 里已注册的 capability 载荷原文不对外暴露，验不了「线上注册的是不是这份」。
