#!/usr/bin/env bash
# =============================================================================
# asar-audit.sh — 紫鸟客户端（Electron 外壳）静态审计一键脚本
# 用法:  APP=/Applications/ziniao.app bash asar-audit.sh
#        APP="/c/Program Files/紫鸟浏览器" bash asar-audit.sh   # Windows(Git Bash)
# 输出:  控制台 + ./evidence/  (asar 文件树、package.json、fuses、go buildinfo)
# 说明:  只读，不修改客户端任何文件；所有提取物落到 evidence/。
# =============================================================================
set -uo pipefail
APP="${APP:-/Applications/ziniao.app}"
OUT="${OUT:-./evidence}"
mkdir -p "$OUT"

echo "== [1] 包结构与版本 ================================================"
if [[ -d "$APP/Contents" ]]; then
  PLIST="$APP/Contents/Info.plist"
  RES="$APP/Contents/Resources"
  BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || echo ziniao)"
  FW="$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
else
  PLIST="$APP/resources/app.asar"; RES="$APP/resources"; BIN="$APP/$(basename "$APP").exe"; FW="$APP/$(basename "$APP").exe"
fi
echo "APP=$APP"
[[ -f "$PLIST" ]] && (plutil -p "$PLIST" 2>/dev/null || python3 -c "import plistlib,sys;print(plistlib.load(open(sys.argv[1],'rb')))" "$PLIST") | tee "$OUT/info-plist.txt" | head -40
[[ -f "$FW" ]] && (plutil -p "${FW%/*}/Resources/Info.plist" 2>/dev/null | grep -iE 'CFBundleVersion|BundleIdentifier' \
  || strings -a "$FW" | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+$') | tee "$OUT/electron-version.txt"

echo
echo "== [2] Electron fuses（安全开关）================================"
python3 - "$BIN" "$FW" <<'PY' | tee "$OUT/fuses.txt"
import sys
NEEDLE=b"dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
NAMES=["RunAsNode","EnableCookieEncryption","EnableNodeOptionsEnvironmentVariable",
       "EnableNodeCliInspectArguments","EnableEmbeddedAsarIntegrityValidation",
       "OnlyLoadAppFromAsar","LoadBrowserProcessSpecificV8Snapshot",
       "GrantFileProtocolExtraPrivileges","WasmTrapHandlers"]
STATE={48:"disabled",49:"enabled",114:"removed"}
for p in sys.argv[1:]:
    try: data=open(p,'rb').read()
    except Exception: continue
    i=data.find(NEEDLE)
    print(f"# binary={p} sentinel={i}")
    if i<0: continue
    ver,cnt=data[i+len(NEEDLE)],data[i+len(NEEDLE)+1]
    print(f"# fuse wire version={ver} count={cnt}")
    for k in range(cnt):
        b=data[i+len(NEEDLE)+2+k]
        print(f"  {NAMES[k] if k<len(NAMES) else k:<38} {STATE.get(b,hex(b))}")
PY

echo
echo "== [3] asar 文件树 / package.json / 硬编码密钥 ===================="
python3 - "$RES/app.asar" "$OUT" <<'PY' | tee "$OUT/asar-summary.txt"
import json,struct,sys,os,re
p,out=sys.argv[1],sys.argv[2]
raw=open(p,'rb').read()
j=json.JSONDecoder(); obj,end=j.raw_decode(raw[16:].decode('utf-8','replace'))
base=8+struct.unpack('<I',raw[4:8])[0]
FILES={}
def walk(n,pre=""):
    for k,v in n.items():
        path=(pre+"/"+k) if pre else k
        if v.get("files") is not None: walk(v["files"],path)
        else: FILES[path]=v
walk(obj["files"])
read=lambda q:(lambda m:raw[base+int(m["offset"]):base+int(m["offset"])+int(m["size"])])(FILES[q])
print(f"entries={len(FILES)} header={base}")
big=sorted(((v.get('size',0),k) for k,v in FILES.items()),reverse=True)[:25]
print("\n-- 最大的 25 个文件 --")
for s,k in big: print(f"{s:>10}  {k}")
if "package.json" in FILES:
    pj=json.loads(read("package.json"))
    print("\n-- package.json --"); print(json.dumps(pj,ensure_ascii=False,indent=2))
    open(os.path.join(out,"package.json"),"w").write(json.dumps(pj,ensure_ascii=False,indent=2))
    print("\n-- kernel 矩阵（定制内核版本）--")
    print(json.dumps(pj.get("packageKernel",{}),ensure_ascii=False,indent=2))
# 主进程 bundle 里找扩展解包口令 / 调试端口 / 代理枚举
cands=[k for k in FILES if re.search(r'entries/main.*\.js$',k)]
blob=b""
for k in cands: blob+=read(k)
txt=blob.decode('utf-8','replace')
print("\n-- 关键词命中 --")
for kw in ["remote-debugging-port","--inspect","sbconfig","getExtensionsPath","can_webdriver",
           "proxy-server","socks5","canvas_fingerprint_info","hardwareConcurrency","webdriver"]:
    print(f"  {kw:<28} {txt.count(kw)}")
for m in re.finditer(r'Path:([^,]{0,40}getExtensionsPath\("([^"]+)"\)[^}]{0,200}?Key:"([^"]*)")',txt):
    print("  [扩展包口令候选]",m.group(0)[:220])
PY

echo
echo "== [4] 原生守护进程（Go）构建信息 ================================"
UNP="$RES/app.asar.unpacked"
for b in "$UNP"/envkit/*; do
  [[ -f "$b" ]] || continue
  echo "--- $(basename "$b")  ($(file -b "$b"))"
  (go version -m "$b" 2>/dev/null | head -20) || strings -a "$b" | grep -m1 -E '^go1\.[0-9]+'
done | tee "$OUT/go-buildinfo.txt"

echo
echo "== [5] 扩展载荷是否加密 =========================================="
python3 - "$UNP/assets/extensions" <<'PY'
import glob,struct,sys
for z in glob.glob(sys.argv[1]+"/*.zip"):
    d=open(z,'rb').read(); c=d.find(b'PK\x01\x02')
    if c<0: print(z,"not a zip"); continue
    flag,method=struct.unpack('<HH',d[c+8:c+12])
    print(f"{z}: encrypted={bool(flag&1)} method={method} "
          f"({'ZipCrypto(可已知明文/口令爆破)' if (flag&1) and method==8 else 'AES/未加密'})")
PY

echo
echo "== 完成：证据已落 $OUT ==========================================="
