# L3 平台子模式框架 `dsh-ecom-platform-framework`

给已装 L2（`dsh-ecom-cbec`）的工作区「装一个平台」：平台身份、平台专项 skill、数据源连接器声明、对 L2 的平台参数覆盖。

框架本身不含业务判断，只提供三样东西：**一份 schema**、**一个可复制模板**、**一个安装器**。

## 结构

```
l3/
├── manifest.json                 框架清单（requires: dsh-ecom-cbec>=0.1.0, browser-farm>=1.1.0）
├── schema/platform.schema.json   平台包 manifest 的字段定义
├── install.sh                    安装器
├── platform-template/            新平台复制骨架（id=example，可直接跑通校验）
└── platforms/
    ├── amazon/                   完整档 full：随包安装 8 层 23 个 skill
    ├── aliexpress/               基线档 baseline：复用 L2 skill，只换平台参数
    ├── ebay/                     基线档 baseline
    ├── lazada/                   基线档 baseline
    ├── shopee/                   基线档 baseline
    ├── tiktokshop/               基线档 baseline
    └── walmart/                  基线档 baseline
```

## 用法

```bash
bash install.sh --list                             # 看有哪些平台包
bash install.sh ebay <已装 L2 的目标目录>            # 安装
bash install.sh ebay <已装 L2 的目标目录> --check    # 只校验不写
bash install.sh ebay <已装 L2 的目标目录> --force    # 覆盖已存在文件
```

落点固定：`<目标目录>/95-engine/platforms/<id>/`。

想真取数时看平台包 manifest 的 `connectors`：`browser-farm` 条目带 `probe_preset`，指向
`connectors/platforms/<probe_preset>.json`（未验字段在预设里标 `未验`，别当数据用）。例：

```bash
GATEWAY_URL=http://127.0.0.1:19671 GATEWAY_TOKEN=... \
  node distribution/connectors/farm-probe.js --platform amazon --query 'wireless earbuds' --cache-bust
```

前置是双证：`<目标目录>/CHIEF-INIT.md` + `<目标目录>/.dsh/skills/ecom-selection/SKILL.md`。缺一个就 FAIL 且**不写任何文件**。

## DSH bundle

只有 `tier=full` 平台自带 `bundle/`。Amazon 的 bundle 包名为 `dsh-ecom-amazon`，每个 skill 的入口为 `bundle/skills/<skill-name>/SKILL.md`。原始层级记录在 [LAYERS.md](platforms/amazon/bundle/LAYERS.md)。

`tier=baseline` 的 eBay、TikTok Shop、Shopee、Lazada、Walmart、AliExpress 依赖 L2 的 `dsh-ecom-cbec` bundle，复用其通用 skills。

在 DS Bot 的 `plugin_manager` 中调用 `install_bundle`，`target` 填本地 bundle 目录的绝对路径。先装 L2 bundle，再按需装 Amazon bundle。

```json
{"action":"install_bundle","target":"/绝对路径/DS-Cross-Border-Workbench/distribution/l2/bundle"}
```

```json
{"action":"install_bundle","target":"/绝对路径/DS-Cross-Border-Workbench/distribution/l3/platforms/amazon/bundle"}
```

工作区安装把分层 skills 写到平台落点。安装和 `--check` 都会校验仓库里的平铺 bundle 镜像，遇到漂移时返回非零退出码。

## 新增一个平台

```bash
cp -R platform-template platforms/<id>
# 改 manifest 的 id（必须等于目录名）/ name / tier / skills / connectors
# 填 overrides/platform.json，费率没确认就保持 null + _note
bash install.sh <id> <目标目录> --check
```

## 硬规则

- **费率/佣金一律 `null` + `"_note": "待业务确认"`**，框架不编数字，`install.sh` 也不校验业务数值。
- Amazon 的 23 个 skill 及其附属文件随包安装，保留 8 层目录。授权归属待定，对外分发前需确认。见 [来源与授权](platforms/amazon/skills/REFERENCES.md)。
- `install.sh` 只写 `<目标目录>`；不碰 `~/ds-bot-workspace`、不碰 DS Bot 状态、不安装 bundle。

## 已知缺口

- 计划第 4 节的 `data_sources`（tier 优先级与降级链）没进 schema：还没有消费方，等有读取方再加，避免先冻错形状。
- L2 版本无法从目标目录读：L2 的 `install.sh` 不把 `manifest.json` 落到目标目录，所以 `requires.dsh-ecom-cbec` 现在只能靠「双证存在」判，判不了版本号。
- 两个平台包的连接器都只是声明，一个都没接授权。
