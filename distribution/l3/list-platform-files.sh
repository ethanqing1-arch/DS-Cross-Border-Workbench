#!/usr/bin/env bash
# list-platform-files.sh —— 唯一一处「平台包要装进工作区的文件」枚举口径
#
# 用法：bash list-platform-files.sh <平台目录>
# 输出：相对路径，一行一个，已排序。
#
# 为什么要有这个文件：这个「该装哪些文件」的口径原本被抄在三个地方
# （l3/install.sh 的复制循环、verify.sh 的期望值、e2e-smoke.sh 的期望值），
# 平台包内容一变就有一处忘记同步，导致验收脚本报假 FAIL。
# 收成一处之后，三边都调它，改口径只改这里。
#
# 口径：
#   - 排除 bundle/：那是给 DSH install_bundle 用的平铺分发形态，
#     文件系统安装落的是按层结构的那份，两者不能重复计入。
#   - 排除 .DS_Store。
set -eu

PLATFORM_DIR="${1:?用法: list-platform-files.sh <平台目录>}"
[ -d "$PLATFORM_DIR" ] || { echo "不是目录：$PLATFORM_DIR" >&2; exit 2; }

cd "$PLATFORM_DIR"
find . -path './bundle' -prune -o -type f ! -name '.DS_Store' -print \
  | sed 's|^\./||' \
  | sort
