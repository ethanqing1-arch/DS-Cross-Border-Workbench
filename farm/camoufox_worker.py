#!/usr/bin/env python3
# =============================================================================
# camoufox_worker.py — Firefox 系深人设后端（账号级常驻，不暴露 CDP）
#
# 为什么不是 CDP：Camoufox 走 Playwright/Juggler 协议；且 launch_server 不支持
# persistent_context（官方注释明确写了），所以"既能持久化 profile 又暴露 ws 端点"
# 这条路不存在。正确的用法是每个账号一个常驻 worker，任务在 worker 内执行。
#
# 用法：
#   /tmp/cfx/bin/python camoufox_worker.py --account cf1 \
#       --tz Asia/Tokyo --lang ja-JP --headless \
#       --profile ./profiles/cf1 [--proxy http://127.0.0.1:18080] [--url https://example.com]
#
# 输出：一行 JSON（UA / webdriver / canvas / WebGL / 语言 / 时区 / 字体探针）
# =============================================================================
import argparse
import json
import os
import sys
import time

from camoufox.sync_api import Camoufox

SCAN = r"""
(async () => {
  const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16).padStart(8, '0'); };
  const draw = () => { const c = document.createElement('canvas'); c.width = 240; c.height = 60; const x = c.getContext('2d');
    x.textBaseline = 'top'; x.font = "14px 'Arial'"; x.fillStyle = '#f60'; x.fillRect(100, 1, 62, 20);
    x.fillStyle = '#069'; x.fillText('cf-probe', 2, 15); return c.toDataURL(); };
  const a = draw(), b = draw();
  const gl = document.createElement('canvas').getContext('webgl');
  const dbg = gl && gl.getExtension('WEBGL_debug_renderer_info');
  const meas = (f) => { const c = document.createElement('canvas').getContext('2d'); c.font = '72px ' + f; return c.measureText('mmmmmmmmmmlli').width; };
  const bases = ['monospace','serif','sans-serif'], bw = bases.map(meas);
  const probe = ['Microsoft YaHei','SimSun','PingFang SC','Hiragino Sans GB','Segoe UI','Menlo','DejaVu Sans','Arial'];
  const fonts = probe.filter(f => bases.some((base,i) => meas('"' + f + '",' + base) !== bw[i]));
  return {
    ua: navigator.userAgent, platform: navigator.platform,
    language: navigator.language, languages: navigator.languages,
    tz: Intl.DateTimeFormat().resolvedOptions().timeZone, tzOffsetMin: new Date().getTimezoneOffset(),
    webdriver: navigator.webdriver, hc: navigator.hardwareConcurrency, dm: navigator.deviceMemory ?? null,
    canvas: { hash: fnv(a), stable: a === b },
    webgl: gl ? { vendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
                  renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER) } : null,
    fonts,
    plugins: navigator.plugins.length,
    mediaDevices: !!(navigator.mediaDevices && navigator.mediaDevices.enumerateDevices),
    toDataURL: Function.prototype.toString.call(HTMLCanvasElement.prototype.toDataURL)
  };
})()
"""

IP_PROBE = r"""
async (url) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch(url, { cache: 'no-store', signal: controller.signal });
    if (!response.ok) throw new Error('IP echo HTTP ' + response.status);
    const { ip } = await response.json();
    if (typeof ip !== 'string' || !ip.trim()) throw new Error('IP echo missing ip');
    return { ip, ipErr: null };
  } catch (error) {
    return { ip: null, ipErr: error.name === 'AbortError' ? 'timeout(3s)' : error.message };
  } finally {
    clearTimeout(timer);
  }
}
"""


def scan_ip(page, no_ip):
    if no_ip:
        return {'ip': 'skipped', 'ipErr': None}
    try:
        return page.evaluate(IP_PROBE, os.environ.get('FARM_IP_ECHO') or 'https://api.ipify.org?format=json')
    except Exception as error:
        return {'ip': None, 'ipErr': str(error)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--account', required=True)
    ap.add_argument('--profile', required=True)
    ap.add_argument('--tz', default='Asia/Shanghai')
    ap.add_argument('--lang', default='zh-CN')
    ap.add_argument('--os', default='macos', choices=['macos', 'windows', 'linux'])
    ap.add_argument('--proxy', default='')
    ap.add_argument('--url', default='about:blank')
    ap.add_argument('--headless', action='store_true')
    ap.add_argument('--task', default='', help='任务 JSON 或 "-" 从 stdin 读：{"type":"goto|eval|shot|scan","params":{...}}')
    a = ap.parse_args()

    os.makedirs(a.profile, exist_ok=True)
    # 时区走进程环境（Firefox 读取 TZ），比 JS 覆写干净
    os.environ['TZ'] = a.tz
    try:
        time.tzset()
    except Exception:
        pass

    opts = dict(
        headless=a.headless,
        persistent_context=True,
        user_data_dir=a.profile,
        locale=[a.lang],
        humanize=True,
        os=[a.os],
    )
    if a.proxy:
        opts['proxy'] = {'server': a.proxy}

    task = None
    if a.task:
        raw = sys.stdin.read() if a.task == '-' else a.task
        task = json.loads(raw)

    with Camoufox(**opts) as ctx:
        page = ctx.pages[0] if getattr(ctx, 'pages', None) else ctx.new_page()
        if task:
            t = task.get('type')
            params = task.get('params') or {}
            if t == 'goto':
                page.goto(params['url'], wait_until='domcontentloaded', timeout=params.get('timeout_ms', 30000))
                # readyState 与 CDP 通道对齐：上层按同一个字段判成功，不用分引擎写法
                try:
                    ready = page.evaluate('document.readyState')
                except Exception:
                    ready = None
                result = {'url': page.url, 'readyState': ready}
            elif t == 'eval':
                result = {'value': page.evaluate(params['expr'])}
            elif t == 'shot':
                shot_path = params.get('path') or os.path.join(a.profile, 'shot.png')
                page.screenshot(path=shot_path, full_page=bool(params.get('full_page')))
                result = {'path': shot_path, 'bytes': os.path.getsize(shot_path)}
            elif t == 'scan':
                probe = page.evaluate(SCAN)
                probe.update(scan_ip(page, params.get('no_ip')))
                result = {'probe': probe}
            else:
                print(json.dumps({'ok': False, 'error': f'unsupported task {t}'}, ensure_ascii=False))
                return 2
            print(json.dumps({'ok': True, 'account': a.account, 'engine': 'camoufox', 'type': t, 'result': result}, ensure_ascii=False))
        else:
            page.goto(a.url, wait_until='domcontentloaded', timeout=30000)
            data = page.evaluate(SCAN)
            out = {'account': a.account, 'engine': 'camoufox', 'profile': a.profile, 'probe': data}
            print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
