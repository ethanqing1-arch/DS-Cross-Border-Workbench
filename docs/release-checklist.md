# 跨浪发布清单

## 构建前

- [ ] `git status --porcelain` 输出为空，`VERSION` 已从上次发布版本递增。
- [ ] `distribution/l1/licence/public.pem` 已替换为真实公钥（首行无 `PLACEHOLDER`，文件内含 `BEGIN PUBLIC KEY`）。替换前只能用 `--allow-placeholder-licence` 构建及核验内部试装包，核验时会打印 `WARN 本包仅供内部试装：含占位授权公钥`。
- [ ] `bash distribution/verify.sh` 和 `bash distribution/flow-smoke.sh` 均以 `FAIL=0`、`RESULT: READY` 结束。
- [ ] 本地已有 `farm/node_modules/ws`，构建和端到端试装使用本地依赖。按需在 macOS 上加 `--dmg`。

```bash
bash distribution/release.sh --dmg
```

默认产物目录为 `distribution/out/`。构建会解包 ZIP、校验清单并在临时工作区试装，全部通过后才将产物放到输出目录。用 `--out <目录>` 可以更改产物目录。

## 检查产物

- [ ] 包内有 `LICENSE`、`VERSION`、`distribution/`、`docs/`、`farm/` 和 `MANIFEST.sha256`。
- [ ] 包内唯一允许的 `.pem` 路径是离线授权公钥 `distribution/l1/licence/public.pem`。所有文件都不得含私钥标记，包括改用其他后缀的文件。
- [ ] 包内无真实凭证或令牌、`.env` 及其变体、`farm/state/`（包括 `farm/state/*.db`）、`farm/profiles/` 或 `distribution/out/`。

## 发出去之前

从仓库根目录运行下列命令。将 ZIP 解包到干净目录，再从解包目录调用随包的 `release.sh --check`，用绝对路径指回待发 ZIP 的目录。把原始核验输出、退出码和产物 SHA256 贴进发布记录。

```bash
artifact_dir="$(pwd -P)/distribution/out"
version="$(cat VERSION)"
trial_dir="$(mktemp -d)"
(
  unzip -q "$artifact_dir/kualang-$version.zip" -d "$trial_dir" &&
  cd "$trial_dir/kualang-$version" &&
  bash distribution/release.sh --check --out "$artifact_dir"
)
```

## 试装者怎么用

1. 解压 ZIP，双击 `distribution/installer/first-run.command`。使用 macOS DMG 时，打开镜像并双击 `install.command`。终端会显示安装到哪个工作区，默认是 `~/kualang-workspace`。见 [首次启动指南](../distribution/installer/FIRST-RUN.md)。
2. 安装完成后，在 DS Bot 的 **Settings → Secrets** 填写所需凭证。在能读取密钥的环境里进入目标工作区，运行 `python3 scripts/credential_check.py`。见 [凭证申请与自检](credentials-setup.md)。
3. 在同一工作区跑一次取数。用 Amazon 官方接口时，将下例的 ASIN 替换为目标站点的真实 ASIN。使用 eBay、农场或代理时，按对应取数步骤操作。见 [SP-API](sp-api-setup.md)、[eBay](ebay-setup.md)、[农场取数](data-fetch-runbook.md)。

   ```bash
   python3 scripts/spapi_fetch.py catalog --asin B0XXXXXXXX --marketplace US --out out/
   ```

4. 按 `data/candidates.sample.csv` 的列准备 `data/candidates.csv`，填入本次取数支持的字段。在工作区运行 `python3 scripts/score_products.py`，打开命令输出里给出的打分表。
