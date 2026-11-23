# distribution/ — 跨境电商版三层分发

这个目录是**交付层**，不是业务代码。装的时候按 **L1 → L2 → L3** 顺序，越往后越依赖前一层。

| 层 | 包 | 入口 | 落点 | 状态 |
|---|---|---|---|---|
| L1 核心 | `browser-farm`（农场 capability） | `farm/mcp/farm-mcp.js` + DS Bot 共享能力注册 | DS Bot 工具表（7 个 `farm_*` 工具） | 已交付（M1），需用户在设置里 Allow |
| L2 版本包 | `dsh-ecom-cbec` | `l2/install.sh <目标目录>` | `<目标>/.dsh/skills/` + 工作区骨架 | 已交付（M2） |
| L3 平台包 | `dsh-ecom-platform-framework` | `l3/install.sh <平台> <目标目录>` | `<目标>/95-engine/platforms/<id>/` | 框架 + 7 个平台已交付（M3 / M4） |

L1 不在这个目录里：农场代码和 capability 适配层在仓库根的 `farm/`，`farm/mcp/farm-mcp.js` 是那 7 个工具的适配层。

## 安装顺序

```bash
# 1) L1：农场起网关（真网关）+ 在 DS Bot 设置里放行 browser-farm
cd farm && bash scripts/start-gateway.sh --daemon

# 2) L2：工作区骨架 + 4 个业务 skill
bash distribution/l2/install.sh ~/ds-bot-workspace

# 3) L3：装平台（可多个，重复装是幂等的）
bash distribution/l3/install.sh amazon   ~/ds-bot-workspace
bash distribution/l3/install.sh ebay     ~/ds-bot-workspace
bash distribution/l3/install.sh --list   # 看全部 7 个

# 4) 播种：由 Main Bot 按 l2/SEED.md 建 10 个 bot、4 个群
```

三个安装器都是**非破坏**语义：已存在的文件跳过，`--force` 才覆盖，`--check` 只校验不写。

## 一条命令验收

```bash
bash distribution/verify.sh            # 跑完清掉临时目录
bash distribution/verify.sh --keep     # 保留临时目录看现场
```

它会在 `mktemp` 目录里依次跑：L2 安装 → 7 个平台逐个安装 → 全量 `--check`（前后 shasum 对比）→ 空目录负例（必须 FAIL 且 0 写入）→ 真工作区 mtime 边界校验，最后打 `PASS/FAIL/WARN` 汇总、`RESULT: READY / NOT_READY` 与退出码（0 / 1）。

依赖：`bash` + `node`（L3 的 manifest 校验用 node；脚本会把 `/opt/homebrew/bin` 补进 PATH）。

## 当前真实 vs 占位

**真的（已验过）**

- L2：30 个工作区文件 + 4 个业务 skill + 10 bot / 4 group 预设 + SEED 剧本，安装幂等。
- L3：schema + 可复制模板（`example` 可直接跑通）+ 安装器（前置双证、非破坏、`--check`、`--force`）。
- 7 个平台包都能装进已装 L2 的目录，每包 4 个文件，重复装/`--check` 都是 0 写入。

**占位（别误读成能直接卖）**

| 占位项 | 现状 |
|---|---|
| 费率/佣金 | 7 个平台的 6 个费率字段**全部 `null`** + `_note: 待业务确认`，一个数字都没填 |
| 官方 API | TikTok Shop / Shopee / Lazada / Walmart / AliExpress / eBay / Amazon 的连接器**全是声明，一个都没接授权** |
| Amazon 专项 skill | 23 个只有**引用声明**（`l3/platforms/amazon/skills/REFERENCES.md`），源码 `cbec-selection-master` 本机不存在，每层数量未统计 |
| 基线平台 skill | eBay / TikTok Shop / Shopee / Lazada / Walmart / AliExpress 都是 `skills.mode=inherit-l2`，没有平台专项 skill |
| DSH bundle | L2 的 `bundle/` 只做静态校验，**没安装**；L3 是文件系统落点，没有 `bundle/` |
| 数据源降级链 | 计划第 4 节的 `data_sources`（tier 优先级与降级）**没进 schema**，还没有消费方 |

## 边界

- `install.sh` / `verify.sh` 只写**目标目录**和 `mktemp` 目录；不碰 DS Bot 应用状态、不碰 farm 台账与服务、不安装 bundle。
- `verify.sh` 默认不写 `~/ds-bot-workspace`（只读它的 mtime 做边界校验）；要真装进去得你显式把那个路径当目标传。
- 不跑 `plugin_manager install`，不碰 launchd。

## 已知缺口（按影响排序）

1. Amazon 名义 `full`，实际只有引用声明；要成真完整档得先把 `cbec-selection-master` 源码给到本机，再改 `skills.mode=bundled`。
2. 费率全 `null`，定价前必须由业务补实值，框架不编数字。
3. 7 个平台的官方 API 都未接入，`browser-farm` 也只声明「只读调研，绝不做登录态店铺操作」。
4. L2 版本判不了：L2 的 `install.sh` 不把 `manifest.json` 落到目标目录，`requires.dsh-ecom-cbec>=0.1.0` 只能靠双证存在判。
5. schema 没有 ajv 级校验，`l3/install.sh` 里是内置子集校验器。
