#!/usr/bin/env bash
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
ROOT="$(cd "$SRC/.." && pwd -P)" || exit 2
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
finish() {
  echo "== 汇总: PASS=$PASS FAIL=$FAIL =="
  if [ "$FAIL" -eq 0 ]; then
    echo 'RESULT: READY'
    exit 0
  fi
  echo 'RESULT: NOT_READY'
  exit 1
}

if ! TMP="$(mktemp -d /tmp/kualang-installer-selftest.XXXXXX)"; then
  bad '无法创建临时目录'
  finish
fi
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
top="kualang-$(cat "$ROOT/VERSION")"

if bash -n "$SRC/installer/first-run.command" && [ -x "$SRC/installer/first-run.command" ]; then
  ok '1. first-run.command 语法正确且可执行'
else
  bad '1. first-run.command 语法错误或不可执行'
fi

archives_ok() {
  mkdir -p "$TMP/tar" "$TMP/zip" &&
  bash "$SRC/make-bundle.sh" --out "$TMP/out" &&
  tar -xzf "$TMP/out/$top.tar.gz" -C "$TMP/tar" &&
  unzip -q "$TMP/out/$top.zip" -d "$TMP/zip" &&
  cmp "$TMP/tar/$top/MANIFEST.sha256" "$TMP/zip/$top/MANIFEST.sha256" &&
  (cd "$TMP/tar/$top" && shasum -c MANIFEST.sha256) &&
  (cd "$TMP/zip/$top" && shasum -c MANIFEST.sha256)
}
if archives_ok >"$TMP/archive.log" 2>&1; then
  ok '2. tar.gz 与 ZIP 的 MANIFEST.sha256 相同，文件逐项校验通过'
else
  bad '2. 打包、解包或 MANIFEST.sha256 核验失败'
  cat "$TMP/archive.log"
fi

verify_entries() {
  local dist="$TMP/zip/$top/distribution" entry
  for entry in verify.sh doctor.sh install-all.sh licence-selftest.sh installer-selftest.sh \
    make-bundle.sh release.sh installer/first-run.command l1/install.sh l1/manifest.json \
    l1/capability/browser-farm.json l1/licence/verify.py l1/plugins/install.js \
    l2/install.sh l2/manifest.json l3/install.sh l3/manifest.json \
    l3/schema/platform.schema.json l3/check-bundle-skills.js \
    connectors/spapi-selftest.sh connectors/ebay-selftest.sh connectors/router-selftest.sh; do
    [ -f "$dist/$entry" ] || { echo "缺 ${entry}"; return 1; }
  done
  [ -x "$dist/installer/first-run.command" ] || { echo 'ZIP 中 first-run.command 不可执行'; return 1; }
}
if verify_entries; then
  ok '3. ZIP 解压后 verify 入口齐全，first-run.command 可执行'
else
  bad '3. ZIP 解压后安装或验收入口缺失'
fi

dmg_volume_ok() {
  local image="$1" mountpoint="$TMP/mounted-dmg" expected actual
  expected="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])' \
    < "$SRC/l1/branding/brand.json")" || return 1
  mkdir "$mountpoint" || return 1
  hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$image" || return 1
  actual="$(/usr/sbin/diskutil info -plist "$mountpoint" | python3 -c \
    'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read())["VolumeName"])')" || actual=
  hdiutil detach "$mountpoint" || return 1
  if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    printf '期望卷标：%s\n实际卷标：%s\n' "$expected" "$actual"
    return 1
  fi
}

if command -v hdiutil >/dev/null 2>&1; then
  if bash "$SRC/make-bundle.sh" --out "$TMP/dmg" --dmg >"$TMP/dmg.log" 2>&1 &&
     hdiutil imageinfo "$TMP/dmg/$top.dmg" >>"$TMP/dmg.log" 2>&1; then
    ok '4. --dmg 产物可由 hdiutil imageinfo 读取'
    if dmg_volume_ok "$TMP/dmg/$top.dmg" >"$TMP/dmg-volume.log" 2>&1; then
      ok '5. DMG 卷标与 brand.json 的 name 一致'
    else
      bad '5. DMG 卷标校验失败'
      cat "$TMP/dmg-volume.log"
    fi
  else
    bad '4. DMG 打包或 hdiutil imageinfo 失败'
    cat "$TMP/dmg.log"
  fi
else
  echo '  WARN 找不到 hdiutil，跳过 DMG 检查'
fi

plugin_ok() {
  local bundle="$TMP/l1/plugins/bundle" target="$TMP/workspace" id
  cp -R "$SRC/l1" "$TMP/l1" && mkdir "$bundle/selftest-fixture" &&
    printf '%s\n' '{"name":"selftest-fixture"}' > "$bundle/selftest-fixture/package.json" || return 1
  GATEWAY_URL=http://127.0.0.1:0 bash "$TMP/l1/install.sh" "$target" --farm "$ROOT/farm" --check &&
    [ ! -e "$target" ] &&
    GATEWAY_URL=http://127.0.0.1:0 bash "$TMP/l1/install.sh" "$target" --farm "$ROOT/farm" &&
    cmp "$bundle/selftest-fixture/package.json" "$target/.dsh/plugins/selftest-fixture/package.json" &&
    grep -Fxq '  PASS 插件已复制：selftest-fixture' "$TMP/plugin.log" &&
    grep -Fxq '== 汇总: write=1 skip=0 fail=0 ==' "$TMP/plugin.log" || return 1
  for id in retrace rollback-withdraw; do
    grep -Fxq "  WARN 插件缺源：$id" "$TMP/plugin.log" || return 1
  done
}
if plugin_ok >"$TMP/plugin.log" 2>&1; then
  ok '6. 插件复制到 .dsh/plugins/selftest-fixture，manifest 缺源项 retrace / rollback-withdraw 均打印 WARN'
else
  bad '6. 插件复制、只读校验或缺源 WARN 断言失败'
  cat "$TMP/plugin.log"
fi

if grep -Eq '^[[:space:]]*python3[[:space:]]+(-B[[:space:]]+)?"\$target/scripts/credential_check\.py"([[:space:]]|$)' \
    "$TMP/zip/$top/distribution/installer/first-run.command"; then
  ok '7. 解包后的 first-run.command 调用已安装的 credential_check.py'
else
  bad '7. 解包后的 first-run.command 缺少对已安装 credential_check.py 的调用'
fi

if (source "$SRC/release.sh" && release_tool payload "$TMP/tar/$top" "$TMP/zip/$top"); then
  ok '8. tar.gz 与 ZIP 均无真实凭证、私钥、farm/state、farm/profiles、.env 或 distribution/out'
else
  bad '8. 发行包载荷安全检查失败'
fi

finish
