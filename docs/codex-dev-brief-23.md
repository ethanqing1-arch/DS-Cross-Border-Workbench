# brief-23：交付包（能直接发给试装者）

## 背景（实测）

打包链路已经有一半了，别重造：

- `distribution/make-bundle.sh` 能出 tar.gz / ZIP / DMG，默认输出 `distribution/out`，版本号读根目录 `VERSION`（`x.y.z`），产物名 `kualang-<version>`，带 `MANIFEST.sha256`。
- `distribution/installer/first-run.command` 已经有 `doctor` → `install-all` → `verify` 三步，并且对 `--target` 做了保护（禁止落到真实 DS Bot 工作区和 `~/.dsh`）。
- `distribution/installer/FIRST-RUN.md` 已存在。
- `installer-selftest.sh` 六条断言覆盖 tar/ZIP 一致、清单校验、DMG 可读。

**缺的是「发出去就能用」这几步：**

1. `first-run.command` 装完只打印「看 README / CHIEF-INIT / data 样例」，**没有凭证自检**。客户装完了也不知道要填 SP-API / eBay 凭证，跑到取数才发现读不到——brief-22 刚把凭证接入层做好，这里必须接上。
2. 没有一条「构建 → 解包 → 真跑一遍」的端到端命令，现在只有 selftest 里各自拆开的检查。
3. 没有发布清单（发出去之前要排除什么、要核对什么），也没有试装说明。
4. **`distribution/out/` 没有被 git 忽略**（`.gitignore` 里只有 `distribution/connectors/out/`、`distribution/l2/workspace/out/*`、`distribution/l3/platforms/*/out/`），构建一次就会把几十 MB 产物挂成未跟踪文件。必须补上忽略规则并加断言。

## 任务

### T1 first-run 接入凭证自检

**文件**：`distribution/installer/first-run.command`

在 `verify` 之后加一步 `credentials`：

- 调用已安装工作区的 `scripts/credential_check.py`（brief-22 新增的那个），**不许失败退出**——客户还没填凭证是正常的；
- 打印逐项状态和一句明确的指引：去哪里填、填完跑哪条命令复核（指向 `docs/credentials-setup.md`）；
- 网关令牌缺失时提示「起网关前需要 GATEWAY_TOKEN」，但同样不阻断安装；
- 最后「下一步做什么」要列出三条：填凭证 → 跑首次取数 → 看打分表。

### T2 一键构建与端到端核验

**新文件**：`distribution/release.sh`

```
用法：bash distribution/release.sh [--out <目录>] [--dmg] [--check]
```

- 默认输出到 `distribution/out`；
- 构建后**自动做一遍端到端**：解包 ZIP 到临时目录 → 校验 `MANIFEST.sha256` → 在临时工作区跑 `first-run.command --target <临时目录>` → 确认退出码 0；
- `--check` 只做核验，不重建。

### T3 发布前清单与试装说明

**新文件**：`docs/release-checklist.md`

必须包含：

- **构建前**：`git status` 干净、`VERSION` 已递增、`verify.sh` / `flow-smoke.sh` 全过；
- **产物必须排除**：真实凭证、`farm/state/*.db`、`farm/profiles/`、`distribution/out` 自身、任何 `*.pem` 私钥、`.env`；
- **产物必须包含**：`LICENSE`、`VERSION`、`distribution/`、`docs/`、`farm/`（不含 state 与 profiles）、`MANIFEST.sha256`；
- **发出去之前**：在干净目录解包跑一次 `release.sh --check`，把结果贴进发布记录；
- **试装者怎么用**：解压 → 双击 `first-run.command` → 装完填凭证 → 跑一次取数。

**更新**：`distribution/installer/FIRST-RUN.md` 补「填凭证」章节，链到 `docs/credentials-setup.md`。

### T4 断言

**`distribution/installer-selftest.sh`** 增加两条：

1. 解包后的 `first-run.command` 里**确实调用了** `credential_check.py`（grep 断言，防止以后被删掉）；
2. 产物里**不含**私钥、`farm/state/*.db`、`farm/profiles/`、`.env`（遍历断言，命中即 FAIL）。

**`distribution/verify.sh`** 增加一节 `7h. 发布包`：至少三条——
1. `release.sh --check` 退出码 0（用临时 `--out`，不许写到真目录）；
2. 产物里能找到 `docs/credentials-setup.md`；
3. 产物不含上面列的禁止项；
4. `git status --porcelain` 在构建后仍然干净（证明 `distribution/out/` 已被忽略）。

### T5 文档

- `README.md`：加「怎么发给别人装」三行（构包 → 解包 → 双击）。
- `docs/roadmap.md`：「装」那行的证据补一句「有可发布的 ZIP/DMG 产物」。

## 范围与红线

- **只许改**：`distribution/installer/first-run.command`、新建 `distribution/release.sh`、新建 `docs/release-checklist.md`、`distribution/installer/FIRST-RUN.md`、`distribution/installer-selftest.sh`、`distribution/verify.sh`、`README.md`、`docs/roadmap.md`、`.gitignore`（只许加 `distribution/out/` 一行）、本交接单「收尾」。
- **不许改**：`make-bundle.sh`（除非发现真实 bug，且必须在收尾里写明改了什么、为什么）、任何 `scripts/*.py`、`farm/`、`score_products.py`、`credential_check.py`。
- **红线**：
  - 产物里绝不允许出现真实凭证、私钥、台账数据库、浏览器 profile；
  - `first-run.command` 的凭证自检**不许失败退出**（客户没填凭证是正常状态）；
  - 不许把 `--target` 的保护逻辑删掉或放宽（它会禁止落到 DS Bot 真实工作区）；
  - 构建过程不许需要联网。
- 镜像同步：`distribution/l2/skills` 与 `distribution/l2/bundle/skills` 的 `diff -qr` 必须零差异。
- **不要 commit、不要 push**，改完停在干净工作区等我验收。

## 收尾

把下面原文追加到本文件末尾：

1. `bash distribution/verify.sh` 汇总行 + `7h` 三条原文；
2. `bash distribution/installer-selftest.sh` 汇总行 + 新增两条原文；
3. 一次真实构建的完整输出（`release.sh`，含产物路径与大小）；
4. 解包后 `first-run.command` 的凭证自检那几行原始输出；
5. `ls -la` 产物目录 + `shasum -c MANIFEST.sha256` 结果；
6. `diff -qr` 镜像结果（应为空）。

### 实测记录

打包器例外修复。原有 Git 文件枚举只读取索引，新建的 `distribution/release.sh` 和 `docs/release-checklist.md` 在未暂存时会漏包。现有打包器只增加这两个明确的文件入口，继续使用原有的排除规则和封装逻辑。

#### 1. `bash distribution/verify.sh` 汇总和 7h 原文

```text
-- 7h. 发布包
  PASS 7h.1 release.sh --check 退出码 0（临时输出目录）
  PASS 7h.2 产物包含 docs/credentials-setup.md
  PASS 7h.3 产物无真实凭证、私钥、farm/state、farm/profiles、.env 或 distribution/out
  PASS 7h.4 构建后 git status --porcelain 仍为空（根 .gitignore 忽略 distribution/out/）
== 汇总: PASS=93 FAIL=0 WARN=1 ==
RESULT: READY
```

退出码 `0`。唯一 WARN 是本轮跳过 Amazon 真实样本需求侧断言。

#### 2. `bash distribution/installer-selftest.sh` 汇总和新增断言原文

```text
  PASS 7. 解包后的 first-run.command 调用已安装的 credential_check.py
  PASS 8. tar.gz 与 ZIP 均无真实凭证、私钥、farm/state、farm/profiles、.env 或 distribution/out
== 汇总: PASS=8 FAIL=0 ==
RESULT: READY
```

退出码 `0`。

#### 3. 真实构建完整输出

执行 `bash distribution/release.sh --out /tmp/kualang-brief23.jLvRhe/out --dmg`，退出码 `0`。

```text
== 构建发行包 ==
发行包：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/artifacts/kualang-0.1.0.tar.gz | 大小=863136 字节 | SHA256=7a27a295673fd50edecb8e836b565f4b57b52ac77ce920959b4fa52707f97bdf
发行包：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/artifacts/kualang-0.1.0.zip | 大小=1125828 字节 | SHA256=1aff31ba808f1e7d715ea1e187d8ac75f2c6d5ddce9d30e40e90688daea63490
发行包：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/artifacts/kualang-0.1.0.dmg | 大小=1718921 字节 | SHA256=ad25f419f24f4f6ad2177a8aa8b9baa765ba19d1d2014ecc17335cb4ff62d15a
文件数=381（含 MANIFEST.sha256）
== 核验 ZIP /private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/artifacts/kualang-0.1.0.zip ==
PASS MANIFEST.sha256（380 个文件）
PASS 发行包通过凭证、私钥、台账、profile 与输出目录检查
目标工作区：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/workspace

== doctor ==
PASS 系统/架构：Darwin arm64
PASS bash 3.2.57(1)-release
PASS node v26.10.0
PASS python3（Python 3.15.2）
PASS git（/opt/homebrew/bin/git）
PASS curl（/usr/bin/curl）
PASS tar（/usr/bin/tar）
PASS 当前目录可用空间 401500088 KiB（至少 1 GiB）
WARN TCP 19671 已被占用，可能已有农场在运行
WARN TCP 19555 已被占用，可能已有农场在运行
WARN 未设置 GATEWAY_TOKEN 或 DSH_SECRET_GATEWAY_TOKEN
PASS farm/node_modules/ws 已就绪
PASS Camoufox Python 已就绪
RESULT: READY

== install-all ==
== L1 ==
== kualang-l1 0.1.0 ==
目标：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/workspace
farm：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/unpacked/kualang-0.1.0/farm
模式：安装
-- 1. manifest
  PASS manifest 可解析（name/version/requires.browser-farm）
-- 2. node 绝对路径
  PASS node 可执行且为绝对路径：/opt/homebrew/bin/node
-- 3. farm 与 stdio 适配层
  PASS farm-mcp.js 存在：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/unpacked/kualang-0.1.0/farm/mcp/farm-mcp.js
  PASS farm-mcp.js 语法通过（node --check）
-- 4. capability 载荷
  PASS 载荷字段齐（name/kind/transport/command/args/env）
  PASS env.GATEWAY_TOKEN 只是 $DSH_SECRET_GATEWAY_TOKEN 占位，无明文 secret
-- 5. 品牌占位
  PASS brand.json 可解析（id/name/colors/icon.path）
  PASS 图标存在且以 <svg 开头
-- 6. 网关可达（只读 /v1/health）
  WARN 网关不可达或未就绪（http://127.0.0.1:0 HTTP=000），只 WARN 不挡安装
-- 7. 随包插件
  WARN 插件缺源：prompt-enhancer
  WARN 插件缺源：retrace
  WARN 插件缺源：rollback-withdraw
-- 8. 标记文件
  write     .dsh/kualang-l1.json
-- 9. 注册与 Allow 步骤
  1) 起网关（令牌只从环境变量，不进 argv）：
       GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash farm/scripts/start-gateway.sh --daemon
  2) 注册共享能力 browser-farm（载荷见 capability/browser-farm.json；本机绝对路径见 .dsh/kualang-l1.json 的 node 和 mcp）：
       kind=mcp   transport=stdio
       command=<node 绝对路径>
       args=[<仓库>/farm/mcp/farm-mcp.js]
       env={GATEWAY_URL=<网关地址>, GATEWAY_TOKEN=$DSH_SECRET_GATEWAY_TOKEN}
       注意：env 里的 token 只是占位符，真值由 DSH 注入，不要写成明文。
  3) 用户本人放行：Settings → Capabilities → Shared capabilities → browser-farm → Allow
  4) 验 7 个工具：tools/list 应见 farm_health / farm_version / farm_sessions /
     farm_session_create / farm_session_delete / farm_task / farm_fingerprint_verify
  5) 收尾：farm_health 应回 ok:true；farm_version 带 require=1.1.0 应 PASS

== 汇总: write=1 skip=0 fail=0 ==
INSTALL OK
PASS L1
== L2 ==
== kualang-cbec 0.1.0 ==
目标：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/workspace
模式：安装（非破坏）
PASS manifest 可解析（name/version/requires.browser-farm/contents.skills）
-- 网关版本闸
WARN 网关不可达（http://127.0.0.1:0），跳过版本闸
-- 空骨架目录
  mkdir     00-inbox/
  mkdir     10-market/
  mkdir     10-market/candidates/
  mkdir     10-market/candidates/_scored/
  mkdir     10-market/competitors/
  mkdir     10-market/keywords/
  mkdir     10-market/trends/
  mkdir     20-products/
  mkdir     30-suppliers/
  mkdir     40-ads/
  mkdir     50-service/
  mkdir     50-service/disputes/
  mkdir     50-service/templates/
  mkdir     60-reports/
  mkdir     60-reports/daily/
  mkdir     60-reports/monthly/
  mkdir     60-reports/weekly/
  mkdir     70-compliance/
  mkdir     70-compliance/certificates/
  mkdir     70-compliance/labels/
  mkdir     70-compliance/tax/
  mkdir     90-templates/
  mkdir     95-engine/
  mkdir     data/
  mkdir     out/
  mkdir     scripts/
-- 工作区文件
  write     00-inbox/.gitkeep
  write     10-market/candidates/.gitkeep
  write     10-market/candidates/_scored/.gitkeep
  write     10-market/competitors/.gitkeep
  write     10-market/keywords/.gitkeep
  write     10-market/trends/.gitkeep
  write     20-products/.gitkeep
  write     30-suppliers/.gitkeep
  write     40-ads/.gitkeep
  write     50-service/disputes/.gitkeep
  write     50-service/templates/.gitkeep
  write     60-reports/daily/.gitkeep
  write     60-reports/monthly/.gitkeep
  write     60-reports/weekly/.gitkeep
  write     70-compliance/certificates/.gitkeep
  write     70-compliance/labels/.gitkeep
  write     70-compliance/tax/.gitkeep
  write     90-templates/daily-report.md
  write     90-templates/listing-brief.md
  write     90-templates/pricing-model.csv
  write     90-templates/selection-score.md
  write     90-templates/service-reply-rules.md
  write     90-templates/supplier-rfq.md
  write     95-engine/.gitkeep
  write     CHIEF-INIT.md
  write     README.md
  write     data/candidates.sample.csv
  write     data/faq.json
  write     data/messages.sample.csv
  write     data/orders.sample.csv
  write     data/products.sample.csv
  write     out/.gitkeep
  write     scripts/credential_check.py
  write     scripts/credentials.py
  write     scripts/cs_router.py
  write     scripts/ebay_fetch.py
  write     scripts/fetch_router.py
  write     scripts/gen_listing.py
  write     scripts/ops_report.py
  write     scripts/score_products.py
  write     scripts/screen_to_candidates.py
  write     scripts/spapi_fetch.py
-- 业务 skills
  write     .dsh/skills/ecom-cs/SKILL.md
  write     .dsh/skills/ecom-ebay/SKILL.md
  write     .dsh/skills/ecom-guardrails/SKILL.md
  write     .dsh/skills/ecom-guardrails/references/action-compliance.md
  write     .dsh/skills/ecom-listing/SKILL.md
  write     .dsh/skills/ecom-ops/SKILL.md
  write     .dsh/skills/ecom-selection/SKILL.md
  write     .dsh/skills/ecom-sp-api/SKILL.md
  write     .dsh/skills/market-research/SKILL.md
  write     .dsh/skills/market-research/references/free-stack-verified.md
  write     .dsh/skills/market-research/references/tool-map.md
  write     .dsh/skills/market-research/scripts/estimate_columns.py
  write     .dsh/skills/market-research/scripts/fetch_aliexpress.py
  write     .dsh/skills/market-research/scripts/fetch_amazon.py
  write     .dsh/skills/market-research/scripts/fixtures/aliexpress_us_trim.html
  write     .dsh/skills/market-research/scripts/fixtures/screen/aliexpress_search.json
  write     .dsh/skills/market-research/scripts/fixtures/screen/amazon_products.json
  write     .dsh/skills/market-research/scripts/fixtures/screen/amazon_products_503.json
  write     .dsh/skills/market-research/scripts/fixtures/screen/amazon_search.json
  write     .dsh/skills/market-research/scripts/screen_keyword.py
PASS skills=8（期望 8）
-- bundle 镜像一致性
PASS bundle/skills 与 skills/ 一致

== 汇总: write=88 skip=0 fail=0 ==
INSTALL OK
下一步：把 DS Bot 工作区指到 /private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/workspace；再由 Main Bot 按 SEED.md 播种 bot 与群。
PASS L2
== L3 amazon ==
== kualang-platform-framework 0.1.0 / 平台包 amazon ==
目标：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/workspace
模式：安装（非破坏）
-- 1. 平台 manifest schema 校验
PASS 平台 manifest 通过 schema 校验（id=amazon tier=full skills.mode=bundled）
PASS overrides 可解析（overrides/platform.json，null 待业务确认 6 个字段）
-- 农场版本闸
WARN 网关不可达，跳过版本闸
-- 2. L2 前置（kualang-cbec 双证）
  PASS CHIEF-INIT.md
  PASS .dsh/skills/ecom-selection/SKILL.md
PASS 目标目录已装 L2（双证齐）
-- 3. 平台包文件 → 95-engine/platforms/amazon/
  write     95-engine/platforms/amazon/README.md
  write     95-engine/platforms/amazon/SKILL_SPEC.md
  write     95-engine/platforms/amazon/data/candidates_sample.csv
  write     95-engine/platforms/amazon/engine/score.py
  write     95-engine/platforms/amazon/engine/selftest.py
  write     95-engine/platforms/amazon/engine/validate_skills.py
  write     95-engine/platforms/amazon/manifest.json
  write     95-engine/platforms/amazon/overrides/platform.json
  write     95-engine/platforms/amazon/skills/00-router/cbec-command/SKILL.md
  write     95-engine/platforms/amazon/skills/01-data/amz-keyword-harvest/SKILL.md
  write     95-engine/platforms/amazon/skills/01-data/amz-keyword-harvest/references/keyword-tier-rules.md
  write     95-engine/platforms/amazon/skills/01-data/amz-listing-scrape/SKILL.md
  write     95-engine/platforms/amazon/skills/01-data/amz-listing-scrape/references/field-mapping.md
  write     95-engine/platforms/amazon/skills/01-data/amz-review-harvest/SKILL.md
  write     95-engine/platforms/amazon/skills/01-data/amz-review-harvest/references/spam-rules.md
  write     95-engine/platforms/amazon/skills/01-data/web-trend-scan/SKILL.md
  write     95-engine/platforms/amazon/skills/01-data/web-trend-scan/references/source-playbook.md
  write     95-engine/platforms/amazon/skills/02-market/market-entry/SKILL.md
  write     95-engine/platforms/amazon/skills/02-market/market-entry/references/entry-scorecard.md
  write     95-engine/platforms/amazon/skills/02-market/market-sizing/SKILL.md
  write     95-engine/platforms/amazon/skills/02-market/market-sizing/references/bsr-sales-table.md
  write     95-engine/platforms/amazon/skills/02-market/market-trend/SKILL.md
  write     95-engine/platforms/amazon/skills/02-market/market-trend/references/season-plan.md
  write     95-engine/platforms/amazon/skills/03-demand/demand-priority/SKILL.md
  write     95-engine/platforms/amazon/skills/03-demand/demand-priority/references/kano-scoring.md
  write     95-engine/platforms/amazon/skills/03-demand/jtbd-map/SKILL.md
  write     95-engine/platforms/amazon/skills/03-demand/jtbd-map/references/scenario-card-template.md
  write     95-engine/platforms/amazon/skills/03-demand/voc-mining/SKILL.md
  write     95-engine/platforms/amazon/skills/03-demand/voc-mining/references/cluster-taxonomy.md
  write     95-engine/platforms/amazon/skills/04-competitor/competitor-deconstruct/SKILL.md
  write     95-engine/platforms/amazon/skills/04-competitor/competitor-deconstruct/references/claim-buckets.md
  write     95-engine/platforms/amazon/skills/04-competitor/negative-review-gap/SKILL.md
  write     95-engine/platforms/amazon/skills/04-competitor/negative-review-gap/references/failure-modes.md
  write     95-engine/platforms/amazon/skills/04-competitor/pricing-ladder/SKILL.md
  write     95-engine/platforms/amazon/skills/04-competitor/pricing-ladder/references/price-test-matrix.md
  write     95-engine/platforms/amazon/skills/04-competitor/visual-strategy/SKILL.md
  write     95-engine/platforms/amazon/skills/04-competitor/visual-strategy/references/main-image-brief.md
  write     95-engine/platforms/amazon/skills/05-product/compliance-gate/SKILL.md
  write     95-engine/platforms/amazon/skills/05-product/compliance-gate/references/compliance-matrix.md
  write     95-engine/platforms/amazon/skills/05-product/decision-control/SKILL.md
  write     95-engine/platforms/amazon/skills/05-product/decision-control/references/scoring-and-card.md
  write     95-engine/platforms/amazon/skills/05-product/profit-model/SKILL.md
  write     95-engine/platforms/amazon/skills/05-product/profit-model/references/fba-fees.md
  write     95-engine/platforms/amazon/skills/05-product/profit-model/references/formula.md
  write     95-engine/platforms/amazon/skills/05-product/supply-verify/SKILL.md
  write     95-engine/platforms/amazon/skills/05-product/supply-verify/references/supplier-scorecard.md
  write     95-engine/platforms/amazon/skills/06-delivery/deck-report/SKILL.md
  write     95-engine/platforms/amazon/skills/06-delivery/deck-report/references/slide-skeleton.md
  write     95-engine/platforms/amazon/skills/06-delivery/excel-report/SKILL.md
  write     95-engine/platforms/amazon/skills/06-delivery/excel-report/references/sheets-columns.md
  write     95-engine/platforms/amazon/skills/07-system/skill-creator/SKILL.md
  write     95-engine/platforms/amazon/skills/07-system/skill-creator/references/admission-gate.md
  write     95-engine/platforms/amazon/skills/07-system/toolchain-dispatch/SKILL.md
  write     95-engine/platforms/amazon/skills/07-system/toolchain-dispatch/references/capability-matrix.md
  write     95-engine/platforms/amazon/skills/REFERENCES.md
  （源文件 55 个）
-- 4. 落点校验
PASS manifest 已落地（95-engine/platforms/amazon/manifest.json）
PASS skills/ 目录存在（47 个文件）
PASS 落点文件数 55 = 源文件数 55
PASS bundle skills 与分层 skills 一致（46 个文件）

== 汇总: write=55 skip=0 fail=0 ==
INSTALL OK
下一步：平台参数在 95-engine/platforms/amazon/overrides/platform.json（现值全是 null，等业务确认）。
PASS L3 amazon
默认平台：amazon。全平台使用 --all-platforms。
下一步：bash distribution/verify.sh
RESULT: READY（PASS=3 FAIL=0）

== verify ==
== kualang 三层总装验收 ==
仓库：/private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/unpacked/kualang-0.1.0
临时根目录：/tmp/kualang-verify.lN5wqF
-- 0. 入口文件
  PASS 存在 l1/install.sh
  PASS 存在 l1/manifest.json
  PASS 存在 l1/capability/browser-farm.json
  PASS 存在 l2/install.sh
  PASS 存在 l2/manifest.json
  PASS 存在 l3/install.sh
  PASS 存在 l3/manifest.json
  PASS 存在 l3/schema/platform.schema.json
  PASS 存在 l3/check-bundle-skills.js
-- 1. L1 核心包 kualang-l1
  PASS L1 install（write=1 skip=0 fail=0）
  WARN L1 网关不可达（安装器只 WARN，未挡安装）
  PASS L1 标记文件可解析（name=kualang-l1 capability=browser-farm）
  PASS L1 --check 幂等（== CHECK: would-write=0 would-skip=1 FAIL=0 ==）
  PASS L1 --check 未改标记文件（shasum 一致 7e6d7e1f39a7…）
  PASS L1 负例 --farm 空目录退出码 1（非 0）
  PASS L1 负例失败原因正确（farm-mcp.js 不存在）
  PASS L1 负例目标 0 写入
-- 2. L2 版本包 kualang-cbec
    == 汇总: write=88 skip=0 fail=0 ==
    INSTALL OK
  PASS L2 install 退出码 0
  PASS L2 汇总 write=88 skip=0 fail=0
  PASS L2 落点文件数 62
  PASS L2 skills=8
  PASS L2 skills 落点与源目录一致（含附属文件）
  PASS L2 工作区随包脚本 10 个 + faq.json 齐全
-- 3. L3 平台包（逐个装）
  PASS 平台清单 7 个
  PASS 平台 aliexpress 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 amazon skills=23
  PASS 平台 amazon 安装（write=55 skip=0 fail=0，落点 55）
  PASS 平台 amazon bundle skills 与分层 skills 一致（46 个文件）
  PASS 平台 ebay 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 lazada 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 shopee 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 tiktokshop 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台 walmart 安装（write=4 skip=0 fail=0，落点 4）
  PASS 平台落点目录 7 个
-- 4. 全量 --check（不写）
  PASS L2 --check 幂等（== CHECK: would-write=0 would-skip=88 FAIL=0 ==）
  PASS 平台 aliexpress --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 amazon --check 幂等（== CHECK: would-write=0 would-skip=55 FAIL=0 ==）
  PASS 平台 ebay --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 lazada --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 shopee --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 tiktokshop --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS 平台 walmart --check 幂等（== CHECK: would-write=0 would-skip=4 FAIL=0 ==）
  PASS --check 未改任何文件（shasum 一致 67e9de8fc7ca…）
-- 5. 负例：空目录装平台必须 FAIL 且 0 写入
  PASS 空目录装 ebay 退出码 1（非 0）
  PASS 空目录失败原因正确（未装 L2）
  PASS 空目录 0 写入
-- 5a. 负例：农场版本不满足必须 FAIL 且 0 写入
  WARN L3 农场版本闸负例跳过：WARN 网关不可达，跳过版本闸
-- 5b. 负例：requires 键名错误必须 FAIL 且 0 写入
  PASS L3 requires 错误键名负例（rc=1，目标 0 写入）
-- 6. 取页器与平台预设（静态）
  PASS node --check farm-probe.js
  PASS 平台预设 7 个齐全
  PASS 预设 aliexpress.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 amazon.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 ebay.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 lazada.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 shopee.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 tiktokshop.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS 预设 walmart.json 合规（id/name/search_url_template/list_selector/fields/verified/notes）
  PASS L3 aliexpress 接上取数预设（browser-farm.probe_preset=aliexpress）
  PASS L3 amazon 接上取数预设（browser-farm.probe_preset=amazon）
  PASS L3 ebay 接上取数预设（browser-farm.probe_preset=ebay）
  PASS L3 lazada 接上取数预设（browser-farm.probe_preset=lazada）
  PASS L3 shopee 接上取数预设（browser-farm.probe_preset=shopee）
  PASS L3 tiktokshop 接上取数预设（browser-farm.probe_preset=tiktokshop）
  PASS L3 walmart 接上取数预设（browser-farm.probe_preset=walmart）
-- 7. SP-API 本地假服务
  PASS SP-API 本地假服务自检（catalog / report）
-- 7a. eBay 本地假服务
  PASS eBay 本地假服务自检（token / search / 429 重试）
-- 7b. 降级链
  PASS 降级链自检（T1 / T3 / E_NO_TIER）
-- 7c. AliExpress 离线币种闸门
  PASS AliExpress 美元样本（≥10 条、分转美元、sold 解析、未验证字段为 null）
  PASS AliExpress 日元样本被拒（非 0 退出，无商品或价格）
-- 7d. 粗筛报告口径
  PASS 粗筛离线运行退出码 0
  PASS 粗筛 Markdown 五节齐全
  PASS 粗筛 CSV 15 项指标齐全，Markdown 和 CSV 无决策词
  PASS 删掉 amazon_products.json 后，上架月龄中位数为 NA（含缺失原因）
  WARN 跳过 Amazon 真实样本需求侧断言（本轮未能取到可用样本，见 docs/amazon-throttle.md）
-- 7e. 粗筛离线重放与估算闸门
  PASS 粗筛在线路径落盘三份 raw，离线重放 CSV 逐字一致
  PASS 连续 503 提前停止，在线及重放报告标记剩余页数，未抓页不计入统计
  PASS 粗筛 CSV 与 JSON 估算一致，五项均有公式、输入指标、证据等级和不确定性
  PASS 估算列保留估算_前缀，选品打分仍为补数据
-- 7f. 证据分层打分
  PASS 7f.1 全缺样例为 D、0/4、补数据，分数和利润留空
  PASS 7f.2 需求与竞争两维最多观察，四维含需求代理仍不能上架
  PASS 7f.3 四维齐、贡献利润厚且无红线时可上架测试
  PASS 7f.4 利润缺失、其他三维满分时仍只观察，诊断与红线标记利润未验
  PASS 7f.5 估算_ 列不计入任何维度，结论仍为补数据
-- 7g. 凭证接入层
  PASS 7g.1 只设 DSH_SECRET_ 前缀，SP-API 和 eBay 通过本地 mock
  PASS 7g.2 只设裸名，SP-API 和 eBay 通过本地 mock
  PASS 7g.3 两种形态同时存在且值不同，两平台均使用前缀值
  PASS 7g.4 自检成功、拒绝和网络失败的输出均无凭证原文（grep -c 为 0）
  PASS 7g.5 全缺凭证时自检退出码为 2，JSON 的 configured 均为 false
-- 7h. 发布包
  INFO 当前处于发行包试装，跳过嵌套发布包核验
-- 8. 授权与安装包自检
  PASS licence-selftest.sh
  INFO 当前处于发行包试装，跳过会重新打包的 installer-selftest.sh
  PASS 真工作区未被写（mtime 未变）

== 汇总: PASS=87 FAIL=0 WARN=3 ==
RESULT: READY

== credentials ==
SP_API_CLIENT_ID | 未配置 | — | 未配置
SP_API_CLIENT_SECRET | 未配置 | — | 未配置
SP_API_REFRESH_TOKEN | 未配置 | — | 未配置
EBAY_CLIENT_ID | 未配置 | — | 未配置
EBAY_CLIENT_SECRET | 未配置 | — | 未配置
提示：凭证待配置或连通性待确认，安装已完成。
GATEWAY_TOKEN | 未配置
提示：起网关前需要 GATEWAY_TOKEN。
请在 DS Bot 的 Settings → Secrets 填写凭证，见 /private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/unpacked/kualang-0.1.0/docs/credentials-setup.md。
填完后，在目标工作区运行 python3 scripts/credential_check.py 复核。

下一步做什么
  1. 按 docs/credentials-setup.md 填凭证并复核。
  2. 按 docs/release-checklist.md 的试装步骤跑首次取数。
  3. 在 /private/var/folders/0z/_d7b43_d30ld1y2gc2mxb3300000gn/T/kualang-release-cqdphd1f/workspace 运行 python3 scripts/score_products.py，打开生成的打分表。
PASS first-run.command 退出码 0
发行包：/private/tmp/kualang-brief23.jLvRhe/out/kualang-0.1.0.dmg | 大小=1718921 字节
发行包：/private/tmp/kualang-brief23.jLvRhe/out/kualang-0.1.0.tar.gz | 大小=863136 字节
发行包：/private/tmp/kualang-brief23.jLvRhe/out/kualang-0.1.0.zip | 大小=1125828 字节
RESULT: READY
```

#### 4. 解包后直接运行 `first-run.command` 的凭证自检原文

在未注入 SP-API、eBay 和网关凭证的环境里，解包后用独立 `--target` 运行，退出码 `0`。

```text
== credentials ==
SP_API_CLIENT_ID | 未配置 | — | 未配置
SP_API_CLIENT_SECRET | 未配置 | — | 未配置
SP_API_REFRESH_TOKEN | 未配置 | — | 未配置
EBAY_CLIENT_ID | 未配置 | — | 未配置
EBAY_CLIENT_SECRET | 未配置 | — | 未配置
提示：凭证待配置或连通性待确认，安装已完成。
GATEWAY_TOKEN | 未配置
提示：起网关前需要 GATEWAY_TOKEN。
请在 DS Bot 的 Settings → Secrets 填写凭证，见 /private/tmp/kualang-brief23.jLvRhe/trial/kualang-0.1.0/docs/credentials-setup.md。
填完后，在目标工作区运行 python3 scripts/credential_check.py 复核。
```

#### 5. 产物目录和清单校验

`ls -la /tmp/kualang-brief23.jLvRhe/out` 原文。

```text
total 7248
drwxr-xr-x@ 5 xavier  wheel      160 Nov 25 08:57 .
drwx------@ 9 xavier  wheel      288 Nov 25 08:58 ..
-rw-r--r--@ 1 xavier  staff  1718921 Nov 25 08:57 kualang-0.1.0.dmg
-rw-r--r--@ 1 xavier  staff   863136 Nov 25 08:57 kualang-0.1.0.tar.gz
-rw-r--r--@ 1 xavier  staff  1125828 Nov 25 08:57 kualang-0.1.0.zip
```

在 ZIP 解包的顶层目录执行 `shasum -c MANIFEST.sha256`，退出码 `0`。以下为逐项原文。

```text
CONTRIBUTING.md: OK
LICENSE: OK
README.md: OK
VERSION: OK
distribution/.gitignore: OK
distribution/README.md: OK
distribution/connectors/README.md: OK
distribution/connectors/ebay-selftest.sh: OK
distribution/connectors/ebay_mock.py: OK
distribution/connectors/farm-probe.js: OK
distribution/connectors/platforms/aliexpress.json: OK
distribution/connectors/platforms/amazon.json: OK
distribution/connectors/platforms/ebay.json: OK
distribution/connectors/platforms/lazada.json: OK
distribution/connectors/platforms/shopee.json: OK
distribution/connectors/platforms/tiktokshop.json: OK
distribution/connectors/platforms/walmart.json: OK
distribution/connectors/router-selftest.sh: OK
distribution/connectors/spapi-selftest.sh: OK
distribution/connectors/spapi_mock.py: OK
distribution/doctor.sh: OK
distribution/e2e-smoke.sh: OK
distribution/flow-smoke.sh: OK
distribution/install-all.sh: OK
distribution/installer/FIRST-RUN.md: OK
distribution/installer/first-run.command: OK
distribution/installer-selftest.sh: OK
distribution/l1/SEED-L1.md: OK
distribution/l1/branding/assets/.gitkeep: OK
distribution/l1/branding/assets/icon.svg: OK
distribution/l1/branding/brand.json: OK
distribution/l1/capability/browser-farm.json: OK
distribution/l1/install.sh: OK
distribution/l1/licence/keygen.sh: OK
distribution/l1/licence/public.pem: OK
distribution/l1/licence/verify.py: OK
distribution/l1/manifest.json: OK
distribution/l1/plugins/bundle/.gitkeep: OK
distribution/l1/plugins/install.js: OK
distribution/l1/plugins/manifest.json: OK
distribution/l2/README.md: OK
distribution/l2/SEED.md: OK
distribution/l2/bundle/cordis.patch.yml: OK
distribution/l2/bundle/package.json: OK
distribution/l2/bundle/skills/ecom-cs/SKILL.md: OK
distribution/l2/bundle/skills/ecom-ebay/SKILL.md: OK
distribution/l2/bundle/skills/ecom-guardrails/SKILL.md: OK
distribution/l2/bundle/skills/ecom-guardrails/references/action-compliance.md: OK
distribution/l2/bundle/skills/ecom-listing/SKILL.md: OK
distribution/l2/bundle/skills/ecom-ops/SKILL.md: OK
distribution/l2/bundle/skills/ecom-selection/SKILL.md: OK
distribution/l2/bundle/skills/ecom-sp-api/SKILL.md: OK
distribution/l2/bundle/skills/market-research/SKILL.md: OK
distribution/l2/bundle/skills/market-research/references/free-stack-verified.md: OK
distribution/l2/bundle/skills/market-research/references/tool-map.md: OK
distribution/l2/bundle/skills/market-research/scripts/estimate_columns.py: OK
distribution/l2/bundle/skills/market-research/scripts/fetch_aliexpress.py: OK
distribution/l2/bundle/skills/market-research/scripts/fetch_amazon.py: OK
distribution/l2/bundle/skills/market-research/scripts/fixtures/aliexpress_us_trim.html: OK
distribution/l2/bundle/skills/market-research/scripts/fixtures/screen/aliexpress_search.json: OK
distribution/l2/bundle/skills/market-research/scripts/fixtures/screen/amazon_products.json: OK
distribution/l2/bundle/skills/market-research/scripts/fixtures/screen/amazon_products_503.json: OK
distribution/l2/bundle/skills/market-research/scripts/fixtures/screen/amazon_search.json: OK
distribution/l2/bundle/skills/market-research/scripts/screen_keyword.py: OK
distribution/l2/install.sh: OK
distribution/l2/manifest.json: OK
distribution/l2/presets/bots.json: OK
distribution/l2/presets/groups.json: OK
distribution/l2/skills/ecom-cs/SKILL.md: OK
distribution/l2/skills/ecom-ebay/SKILL.md: OK
distribution/l2/skills/ecom-guardrails/SKILL.md: OK
distribution/l2/skills/ecom-guardrails/references/action-compliance.md: OK
distribution/l2/skills/ecom-listing/SKILL.md: OK
distribution/l2/skills/ecom-ops/SKILL.md: OK
distribution/l2/skills/ecom-selection/SKILL.md: OK
distribution/l2/skills/ecom-sp-api/SKILL.md: OK
distribution/l2/skills/market-research/SKILL.md: OK
distribution/l2/skills/market-research/references/free-stack-verified.md: OK
distribution/l2/skills/market-research/references/tool-map.md: OK
distribution/l2/skills/market-research/scripts/estimate_columns.py: OK
distribution/l2/skills/market-research/scripts/fetch_aliexpress.py: OK
distribution/l2/skills/market-research/scripts/fetch_amazon.py: OK
distribution/l2/skills/market-research/scripts/fixtures/aliexpress_us_trim.html: OK
distribution/l2/skills/market-research/scripts/fixtures/screen/aliexpress_search.json: OK
distribution/l2/skills/market-research/scripts/fixtures/screen/amazon_products.json: OK
distribution/l2/skills/market-research/scripts/fixtures/screen/amazon_products_503.json: OK
distribution/l2/skills/market-research/scripts/fixtures/screen/amazon_search.json: OK
distribution/l2/skills/market-research/scripts/screen_keyword.py: OK
distribution/l2/workspace/00-inbox/.gitkeep: OK
distribution/l2/workspace/10-market/candidates/.gitkeep: OK
distribution/l2/workspace/10-market/candidates/_scored/.gitkeep: OK
distribution/l2/workspace/10-market/competitors/.gitkeep: OK
distribution/l2/workspace/10-market/keywords/.gitkeep: OK
distribution/l2/workspace/10-market/trends/.gitkeep: OK
distribution/l2/workspace/20-products/.gitkeep: OK
distribution/l2/workspace/30-suppliers/.gitkeep: OK
distribution/l2/workspace/40-ads/.gitkeep: OK
distribution/l2/workspace/50-service/disputes/.gitkeep: OK
distribution/l2/workspace/50-service/templates/.gitkeep: OK
distribution/l2/workspace/60-reports/daily/.gitkeep: OK
distribution/l2/workspace/60-reports/monthly/.gitkeep: OK
distribution/l2/workspace/60-reports/weekly/.gitkeep: OK
distribution/l2/workspace/70-compliance/certificates/.gitkeep: OK
distribution/l2/workspace/70-compliance/labels/.gitkeep: OK
distribution/l2/workspace/70-compliance/tax/.gitkeep: OK
distribution/l2/workspace/90-templates/daily-report.md: OK
distribution/l2/workspace/90-templates/listing-brief.md: OK
distribution/l2/workspace/90-templates/pricing-model.csv: OK
distribution/l2/workspace/90-templates/selection-score.md: OK
distribution/l2/workspace/90-templates/service-reply-rules.md: OK
distribution/l2/workspace/90-templates/supplier-rfq.md: OK
distribution/l2/workspace/95-engine/.gitkeep: OK
distribution/l2/workspace/CHIEF-INIT.md: OK
distribution/l2/workspace/README.md: OK
distribution/l2/workspace/data/candidates.sample.csv: OK
distribution/l2/workspace/data/faq.json: OK
distribution/l2/workspace/data/messages.sample.csv: OK
distribution/l2/workspace/data/orders.sample.csv: OK
distribution/l2/workspace/data/products.sample.csv: OK
distribution/l2/workspace/out/.gitkeep: OK
distribution/l2/workspace/scripts/credential_check.py: OK
distribution/l2/workspace/scripts/credentials.py: OK
distribution/l2/workspace/scripts/cs_router.py: OK
distribution/l2/workspace/scripts/ebay_fetch.py: OK
distribution/l2/workspace/scripts/fetch_router.py: OK
distribution/l2/workspace/scripts/gen_listing.py: OK
distribution/l2/workspace/scripts/ops_report.py: OK
distribution/l2/workspace/scripts/score_products.py: OK
distribution/l2/workspace/scripts/screen_to_candidates.py: OK
distribution/l2/workspace/scripts/spapi_fetch.py: OK
distribution/l3/README.md: OK
distribution/l3/check-bundle-skills.js: OK
distribution/l3/install.sh: OK
distribution/l3/list-platform-files.sh: OK
distribution/l3/manifest.json: OK
distribution/l3/platform-template/README.md: OK
distribution/l3/platform-template/manifest.json: OK
distribution/l3/platform-template/overrides/platform.json: OK
distribution/l3/platform-template/skills/.gitkeep: OK
distribution/l3/platforms/aliexpress/README.md: OK
distribution/l3/platforms/aliexpress/manifest.json: OK
distribution/l3/platforms/aliexpress/overrides/platform.json: OK
distribution/l3/platforms/aliexpress/skills/.gitkeep: OK
distribution/l3/platforms/amazon/README.md: OK
distribution/l3/platforms/amazon/SKILL_SPEC.md: OK
distribution/l3/platforms/amazon/bundle/LAYERS.md: OK
distribution/l3/platforms/amazon/bundle/cordis.patch.yml: OK
distribution/l3/platforms/amazon/bundle/package.json: OK
distribution/l3/platforms/amazon/bundle/skills/amz-keyword-harvest/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/amz-keyword-harvest/references/keyword-tier-rules.md: OK
distribution/l3/platforms/amazon/bundle/skills/amz-listing-scrape/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/amz-listing-scrape/references/field-mapping.md: OK
distribution/l3/platforms/amazon/bundle/skills/amz-review-harvest/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/amz-review-harvest/references/spam-rules.md: OK
distribution/l3/platforms/amazon/bundle/skills/cbec-command/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/competitor-deconstruct/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/competitor-deconstruct/references/claim-buckets.md: OK
distribution/l3/platforms/amazon/bundle/skills/compliance-gate/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/compliance-gate/references/compliance-matrix.md: OK
distribution/l3/platforms/amazon/bundle/skills/decision-control/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/decision-control/references/scoring-and-card.md: OK
distribution/l3/platforms/amazon/bundle/skills/deck-report/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/deck-report/references/slide-skeleton.md: OK
distribution/l3/platforms/amazon/bundle/skills/demand-priority/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/demand-priority/references/kano-scoring.md: OK
distribution/l3/platforms/amazon/bundle/skills/excel-report/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/excel-report/references/sheets-columns.md: OK
distribution/l3/platforms/amazon/bundle/skills/jtbd-map/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/jtbd-map/references/scenario-card-template.md: OK
distribution/l3/platforms/amazon/bundle/skills/market-entry/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/market-entry/references/entry-scorecard.md: OK
distribution/l3/platforms/amazon/bundle/skills/market-sizing/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/market-sizing/references/bsr-sales-table.md: OK
distribution/l3/platforms/amazon/bundle/skills/market-trend/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/market-trend/references/season-plan.md: OK
distribution/l3/platforms/amazon/bundle/skills/negative-review-gap/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/negative-review-gap/references/failure-modes.md: OK
distribution/l3/platforms/amazon/bundle/skills/pricing-ladder/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/pricing-ladder/references/price-test-matrix.md: OK
distribution/l3/platforms/amazon/bundle/skills/profit-model/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/profit-model/references/fba-fees.md: OK
distribution/l3/platforms/amazon/bundle/skills/profit-model/references/formula.md: OK
distribution/l3/platforms/amazon/bundle/skills/skill-creator/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/skill-creator/references/admission-gate.md: OK
distribution/l3/platforms/amazon/bundle/skills/supply-verify/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/supply-verify/references/supplier-scorecard.md: OK
distribution/l3/platforms/amazon/bundle/skills/toolchain-dispatch/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/toolchain-dispatch/references/capability-matrix.md: OK
distribution/l3/platforms/amazon/bundle/skills/visual-strategy/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/visual-strategy/references/main-image-brief.md: OK
distribution/l3/platforms/amazon/bundle/skills/voc-mining/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/voc-mining/references/cluster-taxonomy.md: OK
distribution/l3/platforms/amazon/bundle/skills/web-trend-scan/SKILL.md: OK
distribution/l3/platforms/amazon/bundle/skills/web-trend-scan/references/source-playbook.md: OK
distribution/l3/platforms/amazon/data/candidates_sample.csv: OK
distribution/l3/platforms/amazon/engine/score.py: OK
distribution/l3/platforms/amazon/engine/selftest.py: OK
distribution/l3/platforms/amazon/engine/validate_skills.py: OK
distribution/l3/platforms/amazon/manifest.json: OK
distribution/l3/platforms/amazon/overrides/platform.json: OK
distribution/l3/platforms/amazon/skills/00-router/cbec-command/SKILL.md: OK
distribution/l3/platforms/amazon/skills/01-data/amz-keyword-harvest/SKILL.md: OK
distribution/l3/platforms/amazon/skills/01-data/amz-keyword-harvest/references/keyword-tier-rules.md: OK
distribution/l3/platforms/amazon/skills/01-data/amz-listing-scrape/SKILL.md: OK
distribution/l3/platforms/amazon/skills/01-data/amz-listing-scrape/references/field-mapping.md: OK
distribution/l3/platforms/amazon/skills/01-data/amz-review-harvest/SKILL.md: OK
distribution/l3/platforms/amazon/skills/01-data/amz-review-harvest/references/spam-rules.md: OK
distribution/l3/platforms/amazon/skills/01-data/web-trend-scan/SKILL.md: OK
distribution/l3/platforms/amazon/skills/01-data/web-trend-scan/references/source-playbook.md: OK
distribution/l3/platforms/amazon/skills/02-market/market-entry/SKILL.md: OK
distribution/l3/platforms/amazon/skills/02-market/market-entry/references/entry-scorecard.md: OK
distribution/l3/platforms/amazon/skills/02-market/market-sizing/SKILL.md: OK
distribution/l3/platforms/amazon/skills/02-market/market-sizing/references/bsr-sales-table.md: OK
distribution/l3/platforms/amazon/skills/02-market/market-trend/SKILL.md: OK
distribution/l3/platforms/amazon/skills/02-market/market-trend/references/season-plan.md: OK
distribution/l3/platforms/amazon/skills/03-demand/demand-priority/SKILL.md: OK
distribution/l3/platforms/amazon/skills/03-demand/demand-priority/references/kano-scoring.md: OK
distribution/l3/platforms/amazon/skills/03-demand/jtbd-map/SKILL.md: OK
distribution/l3/platforms/amazon/skills/03-demand/jtbd-map/references/scenario-card-template.md: OK
distribution/l3/platforms/amazon/skills/03-demand/voc-mining/SKILL.md: OK
distribution/l3/platforms/amazon/skills/03-demand/voc-mining/references/cluster-taxonomy.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/competitor-deconstruct/SKILL.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/competitor-deconstruct/references/claim-buckets.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/negative-review-gap/SKILL.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/negative-review-gap/references/failure-modes.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/pricing-ladder/SKILL.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/pricing-ladder/references/price-test-matrix.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/visual-strategy/SKILL.md: OK
distribution/l3/platforms/amazon/skills/04-competitor/visual-strategy/references/main-image-brief.md: OK
distribution/l3/platforms/amazon/skills/05-product/compliance-gate/SKILL.md: OK
distribution/l3/platforms/amazon/skills/05-product/compliance-gate/references/compliance-matrix.md: OK
distribution/l3/platforms/amazon/skills/05-product/decision-control/SKILL.md: OK
distribution/l3/platforms/amazon/skills/05-product/decision-control/references/scoring-and-card.md: OK
distribution/l3/platforms/amazon/skills/05-product/profit-model/SKILL.md: OK
distribution/l3/platforms/amazon/skills/05-product/profit-model/references/fba-fees.md: OK
distribution/l3/platforms/amazon/skills/05-product/profit-model/references/formula.md: OK
distribution/l3/platforms/amazon/skills/05-product/supply-verify/SKILL.md: OK
distribution/l3/platforms/amazon/skills/05-product/supply-verify/references/supplier-scorecard.md: OK
distribution/l3/platforms/amazon/skills/06-delivery/deck-report/SKILL.md: OK
distribution/l3/platforms/amazon/skills/06-delivery/deck-report/references/slide-skeleton.md: OK
distribution/l3/platforms/amazon/skills/06-delivery/excel-report/SKILL.md: OK
distribution/l3/platforms/amazon/skills/06-delivery/excel-report/references/sheets-columns.md: OK
distribution/l3/platforms/amazon/skills/07-system/skill-creator/SKILL.md: OK
distribution/l3/platforms/amazon/skills/07-system/skill-creator/references/admission-gate.md: OK
distribution/l3/platforms/amazon/skills/07-system/toolchain-dispatch/SKILL.md: OK
distribution/l3/platforms/amazon/skills/07-system/toolchain-dispatch/references/capability-matrix.md: OK
distribution/l3/platforms/amazon/skills/REFERENCES.md: OK
distribution/l3/platforms/ebay/README.md: OK
distribution/l3/platforms/ebay/manifest.json: OK
distribution/l3/platforms/ebay/overrides/platform.json: OK
distribution/l3/platforms/ebay/skills/.gitkeep: OK
distribution/l3/platforms/lazada/README.md: OK
distribution/l3/platforms/lazada/manifest.json: OK
distribution/l3/platforms/lazada/overrides/platform.json: OK
distribution/l3/platforms/lazada/skills/.gitkeep: OK
distribution/l3/platforms/shopee/README.md: OK
distribution/l3/platforms/shopee/manifest.json: OK
distribution/l3/platforms/shopee/overrides/platform.json: OK
distribution/l3/platforms/shopee/skills/.gitkeep: OK
distribution/l3/platforms/tiktokshop/README.md: OK
distribution/l3/platforms/tiktokshop/manifest.json: OK
distribution/l3/platforms/tiktokshop/overrides/platform.json: OK
distribution/l3/platforms/tiktokshop/skills/.gitkeep: OK
distribution/l3/platforms/walmart/README.md: OK
distribution/l3/platforms/walmart/manifest.json: OK
distribution/l3/platforms/walmart/overrides/platform.json: OK
distribution/l3/platforms/walmart/skills/.gitkeep: OK
distribution/l3/schema/platform.schema.json: OK
distribution/licence-selftest.sh: OK
distribution/make-bundle.sh: OK
distribution/release.sh: OK
distribution/verify.sh: OK
docs/amazon-skill-licenses.md: OK
docs/amazon-skill-provenance.md: OK
docs/amazon-throttle.md: OK
docs/assets/branding-candidates/01-border-relay-128.png: OK
docs/assets/branding-candidates/01-border-relay-256.png: OK
docs/assets/branding-candidates/01-border-relay-32.png: OK
docs/assets/branding-candidates/01-border-relay.svg: OK
docs/assets/branding-candidates/02-route-junction-128.png: OK
docs/assets/branding-candidates/02-route-junction-256.png: OK
docs/assets/branding-candidates/02-route-junction-32.png: OK
docs/assets/branding-candidates/02-route-junction.svg: OK
docs/assets/branding-candidates/03-shift-handoff-128.png: OK
docs/assets/branding-candidates/03-shift-handoff-256.png: OK
docs/assets/branding-candidates/03-shift-handoff-32.png: OK
docs/branding-candidates.md: OK
docs/branding.md: OK
docs/camoufox-persistent-worker-design.md: OK
docs/codex-dev-brief-10.md: OK
docs/codex-dev-brief-11.md: OK
docs/codex-dev-brief-12.md: OK
docs/codex-dev-brief-13.md: OK
docs/codex-dev-brief-14.md: OK
docs/codex-dev-brief-15.md: OK
docs/codex-dev-brief-16.md: OK
docs/codex-dev-brief-17.md: OK
docs/codex-dev-brief-18.md: OK
docs/codex-dev-brief-19.md: OK
docs/codex-dev-brief-2.md: OK
docs/codex-dev-brief-20.md: OK
docs/codex-dev-brief-21.md: OK
docs/codex-dev-brief-22.md: OK
docs/codex-dev-brief-23.md: OK
docs/codex-dev-brief-3.md: OK
docs/codex-dev-brief-4.md: OK
docs/codex-dev-brief-5.md: OK
docs/codex-dev-brief-6.md: OK
docs/codex-dev-brief-7.md: OK
docs/codex-dev-brief-8.md: OK
docs/codex-dev-brief-9.md: OK
docs/codex-dev-brief.md: OK
docs/credentials-setup.md: OK
docs/data-fetch-runbook.md: OK
docs/ebay-setup.md: OK
docs/external-setup.md: OK
docs/kualang-productization-plan.md: OK
docs/licence.md: OK
docs/m1-increment1.md: OK
docs/m1-increment2.md: OK
docs/onboard-from-zero.md: OK
docs/platform-egress-matrix.md: OK
docs/platform-integrations.md: OK
docs/plugins.md: OK
docs/proposals/retrace.md: OK
docs/proposals/rollback-withdraw.md: OK
docs/proposals/trademark-checklist.md: OK
docs/proxy-runbook.md: OK
docs/release-checklist.md: OK
docs/roadmap.md: OK
docs/sp-api-setup.md: OK
docs/trial-kit.md: OK
farm/README.md: OK
farm/build-fp-chromium.sh: OK
farm/camoufox_worker.py: OK
farm/contract.js: OK
farm/control.js: OK
farm/docker/Dockerfile: OK
farm/docker/README.md: OK
farm/docker/entry.sh: OK
farm/docs/dsbot-workbench-architecture.md: OK
farm/docs/dsbot-workbench-review.md: OK
farm/driver.js: OK
farm/farm.js: OK
farm/gateway/server.js: OK
farm/ledger.js: OK
farm/mcp/farm-mcp.js: OK
farm/node_modules/ws/LICENSE: OK
farm/node_modules/ws/README.md: OK
farm/node_modules/ws/browser.js: OK
farm/node_modules/ws/index.js: OK
farm/node_modules/ws/lib/buffer-util.js: OK
farm/node_modules/ws/lib/constants.js: OK
farm/node_modules/ws/lib/event-target.js: OK
farm/node_modules/ws/lib/extension.js: OK
farm/node_modules/ws/lib/limiter.js: OK
farm/node_modules/ws/lib/permessage-deflate.js: OK
farm/node_modules/ws/lib/receiver.js: OK
farm/node_modules/ws/lib/sender.js: OK
farm/node_modules/ws/lib/stream.js: OK
farm/node_modules/ws/lib/subprotocol.js: OK
farm/node_modules/ws/lib/validation.js: OK
farm/node_modules/ws/lib/websocket-server.js: OK
farm/node_modules/ws/lib/websocket.js: OK
farm/node_modules/ws/package.json: OK
farm/node_modules/ws/wrapper.mjs: OK
farm/package-lock.json: OK
farm/package.json: OK
farm/preflight-build.sh: OK
farm/proxy-bridge.js: OK
farm/scripts/acceptance.sh: OK
farm/scripts/first-fetch.sh: OK
farm/scripts/ledger-clean.sh: OK
farm/scripts/mock-ip-echo.js: OK
farm/scripts/proxy-selftest.sh: OK
farm/scripts/start-gateway.sh: OK
farm/scripts/test-proxy-bridge.sh: OK
farm/scripts/verify-dual-env.sh: OK
farm/verify-egress.js: OK
farm/widevine.sh: OK
```

#### 6. L2 镜像

`diff -qr distribution/l2/skills distribution/l2/bundle/skills` 退出码 `0`，输出为空。

#### 补充验收

- `bash distribution/flow-smoke.sh` 退出码 `0`。

```text
== 汇总: PASS=9 FAIL=0 WARN=3 ==
RESULT: READY
```

- 在干净目录解包后调用随包的 `release.sh --check`，退出码 `0`。核验前后的产物 inode、修改时间、大小和 SHA256 一致。
- 从只读挂载的 DMG 运行 `install.command --target <临时工作区>`，退出码 `0`，挂载已卸除。
- 变异测试确认，移除首次安装的凭证调用会触发自检第 7 条，移除根忽略规则会触发 7h.4。强制凭证自检退出 `71` 后首次安装仍退出 `0`。真实 DS Bot 工作区、`~/.dsh` 以及指向受保护目录的符号链接均被拒绝。
- ZIP 变异测试原文如下。

```text
PASS changed-bytes：MANIFEST.sha256 核验失败
PASS missing-manifest-entry：MANIFEST.sha256 未逐项覆盖
PASS dotenv：发行包含禁止路径：.env
PASS database：发行包含禁止路径：farm/state/ledger.db
PASS profile：发行包含禁止路径：farm/profiles/account/Bookmarks
PASS nested-output：发行包含禁止路径：distribution/out/old.zip
PASS private-pem：发行包含私钥或无法识别的 PEM：docs/custom.pem
PASS private-key-disguised：发行包含私钥或无法识别的 PEM：docs/note.txt
PASS sqlite-renamed：发行包含 SQLite 数据库：farm/store.bin
PASS credential：发行包疑似含真实凭证：docs/note.txt
PASS check-no-rebuild：--check 未调用 ZIP 内的打包器
```
