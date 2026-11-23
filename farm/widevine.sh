#!/usr/bin/env bash
# =============================================================================
# widevine.sh — 把宿主 Chrome 的 Widevine CDM 装进某个 profile（解决 ungoogled 无 DRM）
#
# 用法：bash widevine.sh <profile_dir> [Chrome.app 路径]
# 验证：requestMediaKeySystemAccess('com.widevine.alpha') 由 NotSupportedError 变 OK
# =============================================================================
set -euo pipefail
PROFILE="${1:?usage: widevine.sh <profile_dir> [chrome.app]}"
CHROME_APP="${2:-/Applications/Google Chrome.app}"

CDM=$(ls -d "$CHROME_APP"/Contents/Frameworks/Google\ Chrome\ Framework.framework/Versions/*/Libraries/WidevineCdm 2>/dev/null | sort -V | tail -1)
[ -n "$CDM" ] || { echo "未找到 WidevineCdm：$CHROME_APP"; exit 2; }
VER=$(python3 -c "import json,sys;print(json.load(open('$CDM/manifest.json'))['version'])")

DEST="$PROFILE/WidevineCdm/$VER"
mkdir -p "$DEST"
cp -R "$CDM/manifest.json" "$CDM/_platform_specific" "$CDM/LICENSE" "$DEST/"
echo "installed: $DEST ($(du -sh "$DEST" | cut -f1))"
