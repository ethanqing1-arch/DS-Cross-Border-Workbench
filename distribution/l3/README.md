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
    ├── amazon/                   完整档 full：23 skill 只做引用声明
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

## 新增一个平台

```bash
cp -R platform-template platforms/<id>
# 改 manifest 的 id（必须等于目录名）/ name / tier / skills / connectors
# 填 overrides/platform.json，费率没确认就保持 null + _note
bash install.sh <id> <目标目录> --check
```

## 硬规则

- **费率/佣金一律 `null` + `"_note": "待业务确认"`**，框架不编数字，`install.sh` 也不校验业务数值。
- Amazon 的 23 个 skill 只写引用声明（`platforms/amazon/skills/REFERENCES.md`），**内容不随包分发**：本机没有源码，授权归属也待定。
- `install.sh` 只写 `<目标目录>`；不碰 `~/ds-bot-workspace`、不碰 DS Bot 状态、不安装 bundle。
- 平台包里没有 `bundle/`：本切是文件系统落点，不是 DSH bundle。要变成可 `install_bundle` 的包是下一刀的事。

## 已知缺口

- 计划第 4 节的 `data_sources`（tier 优先级与降级链）没进 schema：还没有消费方，等有读取方再加，避免先冻错形状。
- L2 版本无法从目标目录读：L2 的 `install.sh` 不把 `manifest.json` 落到目标目录，所以 `requires.dsh-ecom-cbec` 现在只能靠「双证存在」判，判不了版本号。
- 两个平台包的连接器都只是声明，一个都没接授权。
