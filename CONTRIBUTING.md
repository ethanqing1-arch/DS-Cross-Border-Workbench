# CONTRIBUTING

本仓是 DS-Cross-Border-Workbench（跨境电商 AI 工作台的能力层与交付层）。改动按下面的规矩来，避免把「能装」改成「只能我这台机器装」。

## 分支与 PR

- 从 `main` 切分支：`feat/<topic>`、`fix/<topic>`、`docs/<topic>`。
- 不直接推 `main`；开 PR，至少 1 人 review 后合并。
- `main` 禁止 force-push；历史只追加，回滚用 revert。

## 提交前必须自检

```bash
bash distribution/verify.sh          # 三层总装验收，必须 FAIL=0 且 RESULT: READY
```

- 改了 `farm/` 代码：先停真网关，再跑 `cd farm && bash scripts/acceptance.sh --with-browser`。
- 改了分发包或 MCP/取页链路：起网关后跑 `bash distribution/e2e-smoke.sh`（需要 `GATEWAY_TOKEN`，只走环境变量）。
- 新增或修改断言后，把 `README.md` 与 `docs/kualang-productization-plan.md` 里的自检计数在**同一个提交**里改掉。

## skills 两份镜像必须同步

`distribution/l2/skills/` 是事实源，`distribution/l2/bundle/skills/` 是运行时镜像。
只改一边会让 `install.sh` 的 `diff -qr` 直接 FAIL：

```bash
rsync -a distribution/l2/skills/ distribution/l2/bundle/skills/
diff -qr distribution/l2/skills distribution/l2/bundle/skills   # 应无输出
```

## 绝不提交

- 密钥、令牌、密码、API key；`.env` 与 `DSH_SECRET_*` 的真值。
- `farm/profiles/`、`farm/state/`、`*.db`（含 `*.db.bak-*`、WAL/SHM）。
- `node_modules/`、`distribution/connectors/out/` 等产物。
- 本机绝对路径（`/Users/...`）。安装器会读的配置用占位符或相对路径，由安装者填。
  例外：`distribution/l1/capability/browser-farm.json` 的 `args` 本身就是本机路径，本地改、不要把本机路径提交上游。

提交前可自查一次（只看文件名与命中行，不打印真值）：

```bash
git diff --cached --name-only | grep -iE '(secret|token|password|credential)' || true
git diff --cached -U0 | grep -inE '(sk-[A-Za-z0-9]{8,}|Bearer [A-Za-z0-9])' || true
```

## 提交信息

一行英文标题（`feat(scope): ...` / `fix(scope): ...` / `docs: ...`），需要时补正文说明动因与验证方式。

## 许可

本仓代码按 Apache-2.0 分发（见 [LICENSE](LICENSE)）；提交即表示同意按同一许可发布。
