# DSH 电商版产品化方案 v1

日期：2026-11-23 (Asia/Shanghai)
状态：待决（第一个平台待定）

## 0 结论摘要

1. 那份 37 项清单里，**通用 9 项只有 4 项能装**，其余 5 项在 npm 上不存在。
2. 清单不是电商能力的真底子。真底子是本机的 `cbec-selection-master`（8 层 23 个 skill + engine + SKILL_SPEC）和自建指纹农场。
3. 三层打包（核心 / 版本 / 平台子模式）用 DSH 原生 bundle + patch + overrides 就能做，**不需要造轮子**。
4. 「选平台装子模式」的供给极不均：Amazon 有两个专项包 + 本机 23 个 skill；eBay 为零。
5. 第二批 13 项里 8 项存在、5 项不存在。**没有现成的多账号指纹农场插件**，自建农场仍不可替代。
6. 商业化刚需的三件——撤销回滚（`dsh-retrace`、`dsh-rollback-withdraw`）与提示词增强（`dsh-prompt-enhancer`）——都可装，进 L1 核心包。

## 1 通用 9 项可装性核查

核验口径：`keywords` 含 `dsh-plugin`、包根 `dsh.bundle.patch` 非空、`dist.integrity` 以 `sha512-` 开头。

| # | 包名 | 结论 | 证据 |
|---|---|---|---|
| 1 | `dsh-plugin-kefu` | **可装** | 0.1.0，2026-10-30，`dsh.bundle.patch=./cordis.patch.yml` |
| 3 | `dsh-psd-batch-studio` | **可装** | 0.2.5，2026-11-06，同上 |
| 4 | `@xiaohe-store/dsh-canvas` | **可装** | 0.1.15，2026-09-17，同上 |
| 5 | `dsh-knowledge-base` | **可装** | 0.1.5，2026-08-16，同上 |
| 2 | `dsh-ecom-image` | **不存在** | npmjs 官方源 E404（同源对照 express 5.3.0 正常返回，排除网络问题） |
| 6 | `dsh-coupon-profit` | **不存在** | E404 |
| 7 | `dsh-shipping-fee` | **不存在** | E404 |
| 8 | `dsh-stock-level` | **不存在** | E404 |
| 9 | `specfusion` | **不存在** | E404 |

替代项：清单第 2 项想要的能力（生图）有现成包 —— `dsh-image-gen@0.11.4`（支持 Gemini / OpenAI / Seedream / DashScope / 本地 ComfyUI 多通道）。**这个直接解决 Visual 当前「没有图片模型接口」的问题**，优先级高于原清单第 2 项。

第 6/7/8 项（优惠券毛利、运费、再订货点）在 npm 上没有任何对口包，只能自建。而且这三项的计算口径是国内的，跨境要按平台佣金 + FBA/头程/尾程重写。

## 1B 第二批 13 项核验

核验口径同上，日期 2026-11-23。

| 分类 | 包名 | 结论 | 证据 |
|---|---|---|---|
| 指纹浏览器 | `dsh-anti-detect-browser` | **可装** | 0.2.1，2026-09-16，真 bundle，关键词含 camoufox/stealth |
| 指纹浏览器 | `dsh-cloak-browser` | **不存在** | E404 |
| 记忆 | `dsh-memory-plugin` | 存在但**不建议装** | 0.7.2，`dsh: {}` 为空，不是 bundle |
| 知识库 | `dsh-library` | **可装** | 0.3.3，2026-11-22，本地文档知识库 |
| 知识库 | `dsh-kb-rag` | **可装** | 1.6.8，2026-10-21，PDF 文献索引 |
| 知识库 | `dsh-weknora` | **不存在** | E404 |
| 知识库 | `dsh-ragflow` | **不存在** | E404 |
| 轨迹回溯 | `dsh-retrace` | **可装，进 L1** | 0.4.154，2026-11-21 |
| 轨迹回溯 | `dsh-rollback-withdraw` | **可装，进 L1** | 0.1.1，2026-08-15，Trae 式撤销 |
| 提示词 | `dsh-prompt-enhancer` | **可装，进 L1** | npm 1.2.2；本机现装 0.1.0（link 到 `~/.dsh/plugins/`，**版本落后**） |
| 跨境业务 | `dsh-plugin-baydeep` | 可装，业务面窄 | 0.1.0，2026-11-10，速卖通联盟 |
| 跨境业务 | `dsh-tool-shopify` | **不存在** | 替代：清单一的 `dsh-shopify-plugins`（213 工具） |
| 国内电商 | `dsh-shop-assistant` | 可装 | 0.1.0，2026-08-15 |
| 国内电商 | `specfusion-dsh` | **不存在** | 与清单一的 `SpecFusion` 同样没有；国内版「平台 API 文档查询」需自建 |

### 四条结论

**1. 没有现成的多账号农场，判断一不变。**
`dsh-anti-detect-browser` 是真的、真 bundle，但读完 README 它是**单会话交互浏览器**：`browser_navigate / snapshot / click / fill / eval / screenshot / close` 共七个工具，给 agent 提供「打开一个网页点点点」的能力。它没有账号池、没有 per-account profile 隔离、没有指纹种子管理、没有台账、不能并行。

我们的农场是「N 个账号的机队」，它是「一个浏览器窗口」。**互补不是替代**：它可以作为 agent 临时看页面、抓单链接的轻量工具，农场继续管并行采集与账号池。

**2. 但它暴露了我们的引擎短板。**
它的关键词里有 `camoufox`，README 写的是双后端。说明 Camoufox 在 DSH 生态里是主流反检测后端。而我们农场 `ENGINE_CAPS` 里的 `camoufox` 是 `degraded`（worker 传输、无 CDP），跑不了 `/v1/tasks`。Camoufox 应当升为一等引擎，见 M1 第 6 项。

**3. `dsh-memory-plugin` 不要装。**
`dsh: {}` 为空不是 bundle，形态与其它插件不同；更要命的是 DS Bot 自带跨会话记忆，再叠一层会互相打架——同一条用户偏好存两处，改一处另一处不改，比不记得更糟。

**4. 三件商业化刚需进 L1。**
`dsh-retrace` 与 `dsh-rollback-withdraw` 是 UI 层的撤销/回滚/编辑重发；`dsh-prompt-enhancer` 是输入框的「✨ Enhance」按钮，用第一性原理重写 prompt、缺信息时反问。做**可商业化的本地部署工作台**，客户误操作能回滚、prompt 能被收敛，是底线能力，不是加分项。

注意 `dsh-prompt-enhancer` 本机原本是 0.1.0、npm 上已 1.2.2，已于 2026-11-23 在本机升级到 1.2.2，待重启验证。


## 2 判断一：把浏览器农场抽成共享能力

### 现状（已核实）

- `control.js` 监听 `127.0.0.1:19555`，路由：实例列表/启动/详情/体检/停止，可选 `x-farm-token`
- `gateway/server.js` 监听 `127.0.0.1:19671`，`Bearer` 鉴权，路由 `/v1/health`、`/v1/sessions`、`/v1/tasks`、`/v1/fingerprint/duplicates`
- `TASK_REGISTRY` 已有 6 类：`goto / eval / click / type / shot / scan`
- 任务带 `task_id` 幂等、`TASK_TTL` 10 分钟
- 台账 `state/farm.db`，`accounts` 表**已有 `platform` 字段**

### 要做的六件事

1. **封成 DSH capability**
   `save_capability kind=mcp transport=streamable-http url=http://127.0.0.1:19671`，header 用 `$DSH_SECRET_GATEWAY_TOKEN`。这样任何 bot、任何子模式都用同一套调用，不各自实现。

2. **补两类任务**（现在的缺口）
   - `extract`：给选择器或字段映射，直接返回结构化 JSON。现在只有 raw `eval`，调用方得自己写 JS 解析，等于把解析逻辑散落到每个子模式里。
   - `wait`：等选择器出现/消失，带超时。现在只能盲等。
   验收：一次 `extract` 拿到 `{title, price, reviews}` 三个字段，不用写一行 JS。

3. **账号按平台分区**
   profile 路径从 `profiles/<account>` 改成 `profiles/<platform>/<account>`。台账 `platform` 字段已有，不用改表。否则 eBay 和 Amazon 的 profile 混在一个池子里，指纹会串。

4. **健康探测改真**
   现在 `engines` 的 `up` 只代表 control 面通（代码里是 `allUp ? 'up' : 'down'`），`running: 0` 时照样显示 up。改成起一个探针实例真跑一次 `goto` 再报。

5. **版本契约**
   每个平台子模式包声明它需要的 `browser-farm` 最低版本，装的时候校验。否则子模式调了旧农场没有的任务类型，报错会很难查。

6. **Camoufox 升为一等引擎**（第二批核验新增）
   现在 `ENGINE_CAPS` 里 `camoufox` 是 `transport: 'worker'` → `/v1/tasks` 直接 422，且 health 恒报 `degraded`。生态里 `dsh-anti-detect-browser` 已经把 Camoufox 当主流反检测后端，我们却只有 worker 一条腿。
   要做：把 `camoufox_worker.py` 的 `goto/eval/shot/scan` 收进统一任务契约，或在 gateway 侧把 worker 传输适配成与 CDP 同形的 `/v1/tasks` 入口，让上层不需要知道引擎差异。

### 验收标准

一个 eBay 账号 + 一个 Amazon 账号同时跑，profile 不串、Cookie 不串、台账能按 platform 筛；`extract` 返回结构化 JSON；健康面在没实例时报 `down` 而不是 `up`；同一个 `goto` 任务在 `chromium` 与 `camoufox` 上返回同形结果。

## 3 判断二：三层打包

### L1 核心包 `dsh-ecom-core`

fork 后保留 `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` 两层，加：品牌化（图标/名称/文案）、授权校验、安装器。内嵌 `browser-farm`。

随包带入的能力（均已核验可装）：

| 包 | 作用 | 为什么在 L1 而不是业务层 |
|---|---|---|
| `dsh-retrace` 0.4.154 | 回溯、编辑重发、重新生成 | 客户误操作的兜底，全业务通用 |
| `dsh-rollback-withdraw` 0.1.1 | Trae 式撤销 | 同上 |
| `dsh-prompt-enhancer` 1.2.2 | 输入框「✨ Enhance」，第一性原理重写 prompt + 缺信息反问 | 降低用户上手门槛，与业务无关 |

`dsh-prompt-enhancer` 已于 2026-11-23 在本机把 `link:` 目录从 0.1.0 换为 npm 1.2.2（旧目录备份在 `~/.dsh/plugins/dsh-prompt-enhancer.bak-0.1.0-20261123`），**待重启 DS Bot 后验证**。

### L2 版本包 `dsh-ecom-cbec`（跨境电商版）

- skills：`cbec-selection-master` 现有 8 层 23 个（00-router / 01-data / 02-market / 03-demand / 04-competitor / 05-product / 06-delivery / 07-system）
- bot presets：Chief / Scout / Source / Margin / Copy / Ads / Care / Compliance / Metrics / Visual
- 工作区模板：README、CHIEF-INIT、90-templates、目录骨架
- 默认群结构：选品决策 / 上架交付 / 增长投放 / 售后风控
- 依赖：`browser-farm >= x`

### L3 平台子模式包

`dsh-ecom-platform-amazon` / `-ebay` / `-tiktokshop` / `-shopee` / `-lazada` / `-walmart` / `-aliexpress`

**平台全部开放**（2026-11-23 定）。每个平台按供给水平分两档，同一套包结构，不等专项包：

| 档 | 条件 | 内容 |
|---|---|---|
| 完整档 | 有专项 skill + 可用数据源 | Amazon（存量 23 skill）、Shopify 生态（`dsh-shopify-plugins` 213 工具） |
| 基线档 | 无专项 skill | 通用选品 skill + 数据源连接器 + `overrides` 换掉平台参数（佣金/履约/税费口径）。eBay、TikTok Shop、Shopee、Lazada、Walmart、AliExpress 先落这档 |

每个声明：平台 skill 集 + 平台数据源连接器（MCP）+ 对 L2 的 `overrides`（例如 eBay 版替换抓取口径、替换定价模型里的佣金参数）。

基线档的价值：**先跑通「装一个平台」这个动作**，专项 skill 后补，不影响产品能卖。

### 机制（DSH 现成，不用造）

- bundle = npm 包根目录的 `dsh.bundle.patch` 指向 `cordis.patch.yml`
- patch 里声明 `rows`（rowId / moduleName / entryId）和 `overrides`
- 安装走 `plugin_manager install_bundle`，装完 `list_bundles` 能看到 rows 和 overrides

已有先例：`deep-view`、`ds-bot`、4 个第三方电商插件都是这个形状。

### 验收标准

空机器上依次装 L1 → L2 → L3，能开一个 bot、进一个群、跑通一次选品并落文件到工作区。

## 4 判断三：数据源

### 三个层 + 降级链

| 层 | 来源 | 拿到什么 | 合规 | 成本 |
|---|---|---|---|---|
| T1 | 平台官方 API | 自家订单/库存/广告/结算，准确 | 最高（要授权与审核） | 低（限流） |
| T2 | 第三方数据（卖家精灵 / Sorftime / Keepa 类） | 竞品、类目、关键词、历史价格 | 中（受条款约束） | 按量付费 |
| T3 | 自建农场抓取 | 页面能看到的一切 | 低（反爬与平台条款风险） | 低（自己维护） |

### 建议的分工

- **选品与类目**：T2 为主（快、稳定），T3 兜底补细节
- **运营数据（订单/库存/广告/结算）**：只走 T1，因为要准，且要能对账
- **红线：绝不用农场做登录态店铺操作**（改价、改库存、发货、回复）。一旦触发平台风控，封的是店，省下的钱远不够赔

### 落地

平台子模式包里声明 `data_sources:` 的 tier 优先级与降级顺序，运行时按声明走，不在 skill 里硬编码。

## 5 顺序与里程碑

| 阶段 | 内容 | 产出 |
|---|---|---|
| M1 | 农场 capability 化（第 2 节六件事，含 Camoufox 归一） | 可被任意 bot 调用的 `browser-farm` |
| M2 | L2 版本包打包 | `dsh-ecom-cbec` 可安装 |
| M3 | 平台子模式框架 + Amazon 完整档（复用存量 23 skill） | 子模式框架成立，Amazon 能跑 |
| M4 | 其余平台铺基线档（eBay/TikTok Shop/Shopee/Lazada/Walmart/AliExpress） | 证明「装一个新平台」可复制 |

M1 和 M2 可以并行。M3 先做 Amazon 不是因为它优先，而是因为它供给最全、能当模板；M4 用同一套模板铺开其余平台。

## 6 未决

1. ~~第一个平台~~ **已定：全部平台开放**（2026-11-23 用户拍板）。L3 不再挑一个先做，按多平台并行设计
2. **商业化形态**：本地部署卖授权，还是别的
3. **`cbec-selection-master` 的授权归属**：是自有资产还是外购，能不能随产品分发
4. **eBay 的供给来源**：清单里零供给，是自建还是找现成包
5. **L1 核心包的 fork 边界**：DSH 上游更新怎么跟进（每个版本都要 rebase，这是长期成本）
6. **`dsh-prompt-enhancer` 重启后要核一件**：新版 patch 插入行带 `id: dsh-prompt-enhancer`，而现有 materialized 配置里是自动生成的 `id: bb3b1c1e`，重启后可能变成两行。若重复，删掉旧的那行再启
7. **Camoufox 归一的工作量未估**：走 worker 适配层还是重做成 CDP 通道，取决于 Camoufox 是否支持 `--remote-debugging-port`，这一点尚未验证
