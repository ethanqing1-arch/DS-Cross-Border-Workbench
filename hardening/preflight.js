#!/usr/bin/env node
/* ============================================================================
 * preflight.js — 派任务前的四方一致性校验（UA / UA-CH / 时区 / 字体 / IP / 完整性）
 *
 * 设计目标：把"能跑"和"跑了不被一眼识破"分开。任何一项 FAIL，就不该把生产账号
 *           放上去。可直接接进 DS-Bot 的任务前置钩子。
 *
 * 用法：
 *   node preflight.js --cdp http://127.0.0.1:19222
 *   node preflight.js --cdp http://127.0.0.1:19222 --expect-ip 203.0.113.10 --expect-tz Asia/Tokyo
 *   node preflight.js --cdp http://127.0.0.1:19222 --strict --json
 *
 * 退出码：0 = 全 PASS（或仅 WARN）；1 = 存在 FAIL；2 = 连接/执行失败
 * 依赖：ws
 * ========================================================================== */
'use strict';
const http = require('http');
const WebSocket = require('ws');

const argv = process.argv.slice(2);
const has = (k) => argv.includes('--' + k);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const CDP = val('cdp', 'http://127.0.0.1:19222').replace(/\/$/, '');
const EXPECT_IP = val('expect-ip', '');
const EXPECT_TZ = val('expect-tz', '');
const STRICT = has('strict');
const JSON_OUT = has('json');

function getJSON(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 5000 }, (res) => {
      let b = ''; res.setEncoding('utf8');
      res.on('data', (c) => (b += c));
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(new Error('bad json')); } });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

class CDPClient {
  constructor(wsUrl) { this.ws = new WebSocket(wsUrl, { perMessageDeflate: false }); this.id = 0; this.pending = new Map(); }
  async open() {
    await new Promise((res, rej) => { this.ws.once('open', res); this.ws.once('error', rej); });
    this.ws.on('message', (raw) => {
      let m; try { m = JSON.parse(raw); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) {
        const { res, rej } = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? rej(new Error(m.error.message)) : res(m.result);
      }
    });
    return this;
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      const timer = setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); rej(new Error(method + ' timeout')); } }, 20000);
      this.pending.set(id, { res: (v) => { clearTimeout(timer); res(v); }, rej: (e) => { clearTimeout(timer); rej(e); } });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text || 'eval exception');
    return r.result && r.result.value;
  }
  close() { try { this.ws.close(); } catch (e) {} }
}

/* 页面内采集：只做"读"，不改任何环境 */
const PROBE = `(async () => {
  const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16).padStart(8, '0'); };
  const ua = navigator.userAgent;
  const ch = navigator.userAgentData ? {
    brands: navigator.userAgentData.brands, platform: navigator.userAgentData.platform, mobile: navigator.userAgentData.mobile
  } : null;
  const draw = () => { const c = document.createElement('canvas'); c.width = 240; c.height = 60;
    const x = c.getContext('2d'); x.textBaseline = 'top'; x.font = "14px 'Arial'";
    x.fillStyle = '#f60'; x.fillRect(100, 1, 62, 20); x.fillStyle = '#069'; x.fillText('ZiNiao-probe-🔍', 2, 15);
    x.fillStyle = 'rgba(102,204,0,0.7)'; x.fillText('ZiNiao-probe-🔍', 4, 17); return c.toDataURL(); };
  const a = draw(), b = draw();
  const cx = document.createElement('canvas').getContext('2d');
  const meas = (f) => { cx.font = '72px ' + f; return cx.measureText('mmmmmmmmmmlli').width; };
  const bases = ['monospace','serif','sans-serif'], bw = bases.map(meas);
  const probe = ['Microsoft YaHei','SimSun','SimHei','PingFang SC','Hiragino Sans GB','Segoe UI','Calibri','Menlo','Monaco','DejaVu Sans','Arial'];
  const fonts = probe.filter(f => bases.some((base,i) => meas('"' + f + '",' + base) !== bw[i]));
  const tz = Intl.DateTimeFormat().resolvedOptions();
  let tzn = '';
  try { tzn = (new Intl.DateTimeFormat('en-US',{timeZone:tz.timeZone,timeZoneName:'shortOffset'}).formatToParts(new Date()).find(p=>p.type==='timeZoneName')||{}).value || ''; } catch(e) {}
  let ip = null;
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 3000);
    const url = globalThis.__FARM_IP_ECHO__ || 'https://api.ipify.org?format=json';
    const r = await fetch(url, { cache: 'no-store', signal: ctl.signal });
    ip = (await r.json()).ip; clearTimeout(t);
  } catch (e) { ip = e.name === 'AbortError' ? 'TIMEOUT' : 'ERR'; }
  const t = (fn) => { try { return Function.prototype.toString.call(fn); } catch(e) { return 'ERR'; } };
  return {
    ua, ch, platform: navigator.platform, languages: navigator.languages, language: navigator.language,
    tz: tz.timeZone, tzOffsetMin: new Date().getTimezoneOffset(), tzName: tzn,
    fonts, canvas: { hash: fnv(a), stable: a === b, len: a.length },
    hc: navigator.hardwareConcurrency, dm: navigator.deviceMemory ?? null,
    screen: { w: screen.width, h: screen.height, dpr: devicePixelRatio },
    webdriver: navigator.webdriver, chrome: !!window.chrome, plugins: navigator.plugins.length,
    integrity: {
      toDataURL: t(HTMLCanvasElement.prototype.toDataURL),
      getContext: t(HTMLCanvasElement.prototype.getContext),
      getParameter: window.WebGLRenderingContext ? t(WebGLRenderingContext.prototype.getParameter) : 'n/a',
      tsSelf: t(Function.prototype.toString)
    },
    privateApi: (() => { try { return typeof (window.chrome && chrome.superbrowser); } catch(e) { return 'err'; } })(),
    ip
  };
})()`;

const R = [];                 // {id, level: PASS|WARN|FAIL, msg, detail}
const push = (id, level, msg, detail) => R.push({ id, level, msg, detail: detail === undefined ? '' : String(detail) });

(async () => {
  const list = await getJSON(CDP + '/json/list');
  const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl) || list.find((t) => t.webSocketDebuggerUrl);
  if (!page) throw new Error('no target at ' + CDP);
  const c = await new CDPClient(page.webSocketDebuggerUrl).open();

  try {
    await c.eval('globalThis.__FARM_IP_ECHO__=' + JSON.stringify(process.env.FARM_IP_ECHO || 'https://api.ipify.org?format=json'));
    const d = await c.eval(PROBE);

    /* 1. UA 与 UA-CH 主版本 */
    const uaMajor = (d.ua.match(/Chrome\/(\d+)/) || [])[1];
    if (!d.ch) push('UA-CH', 'WARN', '无 navigator.userAgentData（Firefox 内核或已禁用）', '');
    else {
      const br = (d.ch.brands || []).find((b) => /Chrome|Chromium/.test(b.brand)) || {};
      push('UA-CH.major', uaMajor && br.version && uaMajor === br.version ? 'PASS' : 'FAIL',
        'UA 主版本 vs UA-CH 版本', `UA=${uaMajor} CH=${br.version}`);
      const platMap = { MacIntel: 'macOS', Win32: 'Windows', Linux: 'Linux' };
      push('UA-CH.platform', platMap[d.platform] === d.ch.platform ? 'PASS' : 'FAIL',
        'navigator.platform vs UA-CH.platform', `${d.platform} / ${d.ch.platform}`);
    }

    /* 2. 时区自洽 + 与期望时区 */
    const offIntl = (() => {
      const m = (d.tzName || '').match(/GMT([+-]\d{1,2})(?::(\d{2}))?/);
      if (!m) return null;
      const sign = m[1][0] === '-' ? -1 : 1;
      return sign * (Math.abs(+m[1]) * 60 + +(m[2] || 0));
    })();
    const offDate = -d.tzOffsetMin;
    push('TZ.self', offIntl === null || Math.abs(offIntl - offDate) <= 60 ? 'PASS' : 'FAIL',
      'Date 偏移 vs Intl 偏移', `Date=${offDate}min Intl=${d.tzName}`);
    if (EXPECT_TZ) push('TZ.expect', d.tz === EXPECT_TZ ? 'PASS' : 'FAIL', '时区与期望一致', `${d.tz} vs ${EXPECT_TZ}`);

    /* 3. 字体 vs UA 平台 */
    const isWin = /Windows NT/.test(d.ua), isMac = /Macintosh/.test(d.ua);
    let fontOk = true, fontDetail = d.fonts.join(',');
    if (isWin && d.fonts.includes('PingFang SC')) { fontOk = false; fontDetail += ' | Windows UA 命中 PingFang SC'; }
    if (isMac && (d.fonts.includes('Microsoft YaHei') || d.fonts.includes('SimSun'))) { fontOk = false; fontDetail += ' | macOS UA 命中 Windows 字体'; }
    if (d.fonts.length === 0) { fontOk = false; fontDetail = '字体探针零命中'; }
    push('FONT.platform', fontOk ? 'PASS' : 'FAIL', '字体集合与 UA 平台一致', fontDetail);

    /* 4. 语言自洽 */
    push('LANG', (d.languages && d.languages[0] === d.language) ? 'PASS' : 'WARN',
      'navigator.language vs languages[0]', `${d.language} / ${(d.languages || []).join(',')}`);

    /* 5. Canvas 稳定性 */
    push('CANVAS.stable', d.canvas.stable ? 'PASS' : 'FAIL', '两次新建 canvas 结果一致', `hash=${d.canvas.hash} len=${d.canvas.len}`);

    /* 6. 函数完整性（JS 层注入的直接指纹） */
    const hooked = Object.entries(d.integrity).filter(([, v]) => typeof v === 'string' && !/\[native code\]/.test(v));
    push('INTEGRITY', hooked.length ? 'FAIL' : 'PASS', '关键函数是否 native', hooked.length ? JSON.stringify(hooked.map(([k]) => k)) : 'all native');

    /* 7. 自动化痕迹 */
    push('WEBDRIVER', d.webdriver === false ? 'PASS' : (STRICT ? 'FAIL' : 'WARN'),
      'navigator.webdriver', String(d.webdriver));
    push('PLUGINS', d.plugins > 0 ? 'PASS' : 'WARN', 'navigator.plugins 数量（Chrome 应为 5）', String(d.plugins));
    push('PRIVATE_API', d.privateApi === 'undefined' ? 'PASS' : 'WARN', 'chrome.superbrowser 私有 API 可见性', d.privateApi);

    /* 8. 出口 IP */
    if (EXPECT_IP) push('IP', d.ip === EXPECT_IP ? 'PASS' : 'FAIL', '页面出口 IP 与期望一致', `${d.ip} vs ${EXPECT_IP}`);
    else push('IP', d.ip ? (d.ip === 'ERR' ? 'WARN' : 'PASS') : 'WARN', '页面出口 IP（未给期望值，仅记录）', d.ip);

    const fails = R.filter((x) => x.level === 'FAIL');
    const warns = R.filter((x) => x.level === 'WARN');
    if (JSON_OUT) {
      console.log(JSON.stringify({ cdp: CDP, target: page.url, result: R, summary: { fail: fails.length, warn: warns.length }, snapshot: d }, null, 2));
    } else {
      console.log(`target: ${page.url}\n`);
      console.log('ID'.padEnd(16), 'LEVEL'.padEnd(6), 'DETAIL');
      for (const x of R) console.log(String(x.id).padEnd(16), String(x.level).padEnd(6), `${x.msg} → ${x.detail}`);
      console.log(`\nsummary: FAIL=${fails.length} WARN=${warns.length} → ${fails.length ? 'BLOCK' : 'ALLOW'}`);
    }
    process.exitCode = fails.length ? 1 : 0;
  } finally {
    c.close();
  }
})().catch((e) => { console.error('ERR:', e.message); process.exitCode = 2; });
