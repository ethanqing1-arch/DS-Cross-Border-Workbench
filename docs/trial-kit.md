# 发行包试装指南

## 15 分钟试装

拿到 `dsh-ecom-0.1.0.tar.gz` 后，在压缩包所在目录打开 Bash。下面的命令会解压到新的临时目录，并把 Amazon 试装到该目录下的 `workspace/`。

```bash
trial_dir="$(mktemp -d /tmp/dsh-trial.XXXXXX)"
time (
  tar -xzf dsh-ecom-0.1.0.tar.gz -C "$trial_dir" &&
  cd "$trial_dir/dsh-ecom-0.1.0" &&
  bash distribution/doctor.sh &&
  bash distribution/install-all.sh "$trial_dir/workspace" &&
  bash distribution/verify.sh
)
```

macOS 基线实测中，`doctor.sh` 为 `RESULT: READY`，默认安装为 `RESULT: READY（PASS=3 FAIL=0）`，`verify.sh` 末尾如下。基线机器已有可用网关和默认工作区。初次试装时，如果缺少其中任一项，保留实际 `WARN` 一起回报。试装到此只验环境和安装链。

```text
== 汇总: PASS=63 FAIL=0 WARN=0 ==
RESULT: READY
```

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统与架构 | macOS Apple Silicon（`Darwin arm64`）为实测基线。Windows 原生环境不支持。用 WSL2 试装时，参照 [外部安装指南 §8](external-setup.md#8-平台差异) 的 Linux 行。 |
| Bash | 3.2 或更新版本 |
| Node.js | 主版本至少 18，且在 `PATH` 中 |
| Python | `python3` 在 `PATH` 中 |
| 命令行工具 | `git`、`curl`、`tar` 可用 |
| 磁盘 | 当前目录可用空间低于 1 GiB 会收到 `WARN` |

## 回报模板

```bash
uname -s -m
node -v
python3 -V
```

复制下面这段，贴入实际输出。总耗时填 `time` 输出里的 `real`。

```text
OS/arch：
node 版本：
Python 版本：
doctor 末尾（含 WARN 和 RESULT）：
verify 末尾（汇总和 RESULT）：
失败原文（含失败命令和输出，或填「无」）：
总耗时：
```

## 常见故障

| 实测原文 | 含义与处理 |
| --- | --- |
| `WARN 未设置 GATEWAY_TOKEN 或 DSH_SECRET_GATEWAY_TOKEN` | 两个变量都未设置时，环境体检仍可就绪。做需要鉴权的网关操作前，从环境注入令牌。 |
| `FAIL PATH 里找不到 node。Apple Silicon 的 Homebrew 安装通常在 /opt/homebrew/bin。` | 把 Node.js 的安装目录加进当前终端的 `PATH`，再跑环境体检。 |
| `WARN TCP 19671 已被占用，可能已有农场在运行` / `WARN TCP 19555 已被占用，可能已有农场在运行` | 已有进程在对应端口监听。确认是否是现有网关或控制端后，可以继续试装。 |
| `WARN 网关令牌少于 32 个字符` | 环境体检可以通过。该项只检查长度，正式使用前应换成长令牌。 |
