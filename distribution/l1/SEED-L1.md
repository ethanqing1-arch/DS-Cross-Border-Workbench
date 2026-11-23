# SEED-L1 — 把 browser-farm 接进 DS Bot（五步）

前置：本机有仓库与 node；`GATEWAY_TOKEN` 已作为 DSH 密钥保存（名字 `GATEWAY_TOKEN`，≥32 位）；令牌只从环境变量走，不进 argv、不进文件。

装包只写标记文件，真正的注册在 DS Bot 设置里做，Allow 只能用户本人点。

## 1. 起网关

```bash
cd <仓库>/farm
GATEWAY_TOKEN="$DSH_SECRET_GATEWAY_TOKEN" bash scripts/start-gateway.sh --daemon
bash scripts/start-gateway.sh --status
```

验（免鉴权端点，只读）：

```bash
curl -sS -w "\nHTTP=%{http_code}\n" http://127.0.0.1:19671/v1/health
# 期望：{"ok":true,"gateway":"up","control":"up","version":"1.1.0",...} HTTP=200
```

鉴权面要单独验，别拿 health 当反证：

```bash
printf 'header = "Authorization: Bearer %s"\n' "$DSH_SECRET_GATEWAY_TOKEN" \
  | curl -sS -K - -o /dev/null -w 'HTTP=%{http_code}\n' http://127.0.0.1:19671/v1/sessions
# 期望 HTTP=200；不带 token 时应 401
```

## 2. 注册共享能力

用 `distribution/l1/capability/browser-farm.json` 里的载荷注册（DS Bot 侧：共享能力 / `save_capability`）：

```
name      = browser-farm
kind      = mcp
transport = stdio
command   = /opt/homebrew/bin/node
args      = ["<仓库绝对路径>/farm/mcp/farm-mcp.js"]
env       = { GATEWAY_URL: "http://127.0.0.1:19671",
              GATEWAY_TOKEN: "$DSH_SECRET_GATEWAY_TOKEN" }
```

三条硬规则：

- `args` 必须绝对路径（stdio 启动时工作目录不确定）。
- `env.GATEWAY_TOKEN` 只能写 `$DSH_SECRET_GATEWAY_TOKEN` 占位，真值由 DSH 注入。
- 改了载荷要重新注册，DS Bot 里存的旧载荷不会自动跟着变。

然后把它挂到需要它的 Bot（`attach_capability`）。

## 3. 用户本人 Allow

Settings → Capabilities → Shared capabilities → `browser-farm` → **Allow**。

本地命令型 MCP 必须真人点一次，任何 Bot 都代不了。Allow 之后，Bot 的工具表里才会出现 7 个 `farm_*` 工具。

## 4. 验 7 个工具

`tools/list` 应见：

```
farm_health / farm_version / farm_sessions / farm_session_create /
farm_session_delete / farm_task / farm_fingerprint_verify
```

再各调一次（顺序建议）：

```
farm_health                        → ok:true, version:1.1.0
farm_sessions                      → 能列会话（鉴权面证据）
farm_session_create(account=…)     → running + check.ok
farm_task(type=goto, url=…)        → succeeded
farm_task(type=extract, selector_map=…) → fields
farm_session_delete(session_id=…)  → stopped, data_retained:true
farm_fingerprint_verify(session_id=…) → ok:true
```

会话创建/删除要带 `Idempotency-Key`（适配层会自动生成；手打 curl 时别忘）。

## 5. 收尾

- `farm_version` 带 `require=1.1.0`，返回 409 `E_VERSION_REQUIRED` 说明农场版本不够。
- 验收时别新增台账行：复用已有账号（如 `mcp-selftest`），用完删会话。
- 令牌长度低于 32 位要换（只报长度，不打印值）。
- 回滚：Settings 里把 `browser-farm` 关掉/解绑，再删目标目录下的 `.dsh/ecom-l1.json` 标记即可；农场本身不受影响。
