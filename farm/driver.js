#!/usr/bin/env node
/* ============================================================================
 * driver.js — 裸 CDP 驱动（不装 Playwright / Puppeteer）
 *
 * 存在意义：Playwright 的 connect_over_cdp 会注入自己的初始化脚本与绑定，
 * 页面里可能留下 __playwright* 之类痕迹。用裸 CDP 驱动则不会引入任何框架痕迹，
 * 这也是"零自动化指纹"路线里唯一干净的一层。
 *
 * 用法：
 *   node driver.js --cdp http://127.0.0.1:19401 scan
 *   node driver.js --cdp ... goto --url "https://example.com"
 *   node driver.js --cdp ... eval --expr "document.title"
 *   node driver.js --cdp ... click --x 100 --y 200
 *   node driver.js --cdp ... type --text "hello"
 *   node driver.js --cdp ... shot --path /tmp/a.png
 *
 * 依赖：ws
 * ========================================================================== */
'use strict';
const fs = require('fs');
const http = require('http');
const WebSocket = require('ws');

const argv = process.argv.slice(2);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const CDP = val('cdp', 'http://127.0.0.1:19401').replace(/\/$/, '');
// 取第一个「不是选项值」的裸词作为子命令
const OPTS = new Set(['--cdp', '--url', '--expr', '--x', '--y', '--text', '--path',
  '--selector-map', '--timeout', '--selector', '--state', '--timeout-ms']);
let cmd = 'scan';
for (let i = 0; i < argv.length; i++) {
  if (OPTS.has(argv[i])) { i++; continue; }
  if (!argv[i].startsWith('--')) { cmd = argv[i]; break; }
}

const getJSON = (url, t = 3000) => new Promise((resolve, reject) => {
  const req = http.get(url, { timeout: t }, (r) => { let b = ''; r.on('data', (c) => (b += c)); r.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } }); });
  req.on('timeout', () => req.destroy(new Error('timeout')));
  req.on('error', reject);
});

async function connect() {
  const list = await getJSON(CDP + '/json/list');
  const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (!page) throw new Error('no page target');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0; const pending = new Map();
  await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  ws.on('message', (raw) => {
    const m = JSON.parse(raw);
    if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); }
  });
  const send = (method, params = {}) => new Promise((res, rej) => {
    const i = ++id;
    const t = setTimeout(() => rej(new Error(method + ' timeout')), 15000);
    pending.set(i, { res: (v) => { clearTimeout(t); res(v); }, rej: (e) => { clearTimeout(t); rej(e); } });
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  const evalJS = async (expr) => {
    const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text || 'eval error');
    return r.result.value;
  };
  return { send, evalJS, close: () => ws.close() };
}

const SCAN = `(() => {
  const pat = /^(__(playwright|puppeteer|nightmare|selenium)|cdc_|\\$cdc|_Selenium|__driver|__webdriver)/i;
  const bad = Object.keys(window).filter(k => pat.test(k));
  const desc = (o, p) => { try { const d = Object.getOwnPropertyDescriptor(o, p); return d ? Object.keys(d).join(',') : null; } catch (e) { return 'ERR'; } };
  return {
    webdriver: navigator.webdriver,
    automationKeys: bad,
    chromeRuntime: !!(window.chrome && window.chrome.runtime),
    plugins: navigator.plugins.length,
    mimeTypes: navigator.mimeTypes.length,
    outer: [window.outerWidth, window.outerHeight],
    toDataURL: Function.prototype.toString.call(HTMLCanvasElement.prototype.toDataURL),
    // 决定性检查：内核级补丁不会有 JS 函数可反查；JS 补丁会在这里露出源码
    crossRealmNative: (() => {
      try {
        const f = document.createElement('iframe'); document.body.appendChild(f);
        const s = f.contentWindow.Function.prototype.toString.call(HTMLCanvasElement.prototype.toDataURL);
        f.remove();
        return /\[native code\]/.test(s);
      } catch (e) { return 'ERR'; }
    })(),
    tsSelf: Function.prototype.toString.call(Function.prototype.toString),
    webdriverDesc: desc(Navigator.prototype, 'webdriver'),
    ua: navigator.userAgent, hc: navigator.hardwareConcurrency
  };
})()`;

(async () => {
  const c = await connect();
  try {
    if (cmd === 'scan') {
      const r = await c.evalJS(SCAN);
      const clean = r.webdriver === false && r.automationKeys.length === 0
        && /\[native code\]/.test(r.toDataURL) && r.crossRealmNative === true;
      console.log(JSON.stringify(Object.assign({ verdict: clean ? 'CLEAN' : 'RISK' }, r), null, 2));
      process.exitCode = clean ? 0 : 1;
    } else if (cmd === 'extract') {
      const url = val('url', '');
      const tmo = Math.max(1000, parseInt(val('timeout', '15000'), 10) || 15000);
      let map;
      try { map = JSON.parse(val('selector-map', '{}')); } catch (e) { throw new Error('bad --selector-map JSON'); }
      if (!map || typeof map !== 'object' || Array.isArray(map)) throw new Error('--selector-map must be a JSON object');
      const t0 = Date.now();
      if (url) {
        await c.send('Page.enable');
        await c.send('Page.navigate', { url });
        let state = null;
        while (Date.now() - t0 < tmo) {
          await new Promise((r) => setTimeout(r, 200));
          state = await c.evalJS('document.readyState').catch(() => null);
          if (state === 'complete') break;
        }
        if (state !== 'complete') {
          console.log(JSON.stringify({ ok: false, url: await c.evalJS('location.href').catch(() => url), readyState: state, error: 'navigation timeout' }));
          process.exitCode = 1;
          return;
        }
      }
      let fields = {}, missing = [];
      for (;;) {
        fields = {}; missing = [];
        for (const [k, sel] of Object.entries(map)) {
          const v = await c.evalJS(`(() => { const el = document.querySelector(${JSON.stringify(String(sel))}); return el ? (el.textContent || '').trim() : null; })()`);
          fields[k] = v;
          if (v === null) missing.push(k);
        }
        if (!missing.length || Date.now() - t0 >= tmo) break;
        await new Promise((r) => setTimeout(r, 200));
      }
      const pageUrl = await c.evalJS('location.href').catch(() => url || null);
      console.log(JSON.stringify({ ok: missing.length === 0, url: pageUrl, fields, missing }));
      process.exitCode = 0;   // 字段缺失不算执行失败（ok 字段已表达）；硬失败只剩导航超时/参数错误
    } else if (cmd === 'wait') {
      const selector = val('selector');
      if (!selector) throw new Error('--selector required');
      const state = val('state', 'present');
      if (state !== 'present' && state !== 'absent') throw new Error('--state must be present|absent');
      const tmo = Math.max(0, parseInt(val('timeout-ms', '30000'), 10) || 30000);
      const t0 = Date.now();
      let found = null;
      for (;;) {
        found = await c.evalJS(`!!document.querySelector(${JSON.stringify(String(selector))})`).catch(() => null);
        const met = state === 'present' ? found === true : found === false;
        if (met || Date.now() - t0 >= tmo) break;
        await new Promise((r) => setTimeout(r, 200));
      }
      const met = state === 'present' ? found === true : found === false;
      console.log(JSON.stringify({ ok: met, selector, state, found, waited_ms: Date.now() - t0 }));
      process.exitCode = met ? 0 : 1;
    } else if (cmd === 'goto') {
      const url = val('url');
      await c.send('Page.enable');
      await c.send('Page.navigate', { url });
      let state = null;
      for (let i = 0; i < 30; i++) {
        await new Promise((r) => setTimeout(r, 200));
        state = await c.evalJS('document.readyState').catch(() => null);
        if (state === 'complete') break;
      }
      console.log(JSON.stringify({ ok: state === 'complete', url: await c.evalJS('location.href'), readyState: state }));
      process.exitCode = state === 'complete' ? 0 : 1;
    } else if (cmd === 'eval') {
      const expr = val('expr');
      const v = await c.evalJS(expr);
      console.log(typeof v === 'string' ? v : JSON.stringify(v, null, 2));
    } else if (cmd === 'click') {
      const x = Number(val('x', '10')), y = Number(val('y', '10'));
      for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
        await c.send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: type === 'mouseMoved' ? 0 : 1 });
        await new Promise((r) => setTimeout(r, 30));
      }
      console.log(JSON.stringify({ ok: true, x, y }));
    } else if (cmd === 'type') {
      const text = val('text', '');
      if (argv.includes('--keys')) {
        // 真实按键：产生 keydown/keyup（isTrusted=true），适合需要事件序列的页面
        for (const ch of text) {
          const code = 'Key' + ch.toUpperCase();
          const vk = ch.toUpperCase().charCodeAt(0);
          await c.send('Input.dispatchKeyEvent', { type: 'keyDown', text: ch, unmodifiedText: ch, key: ch, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk });
          await new Promise((r) => setTimeout(r, 20));
          await c.send('Input.dispatchKeyEvent', { type: 'keyUp', key: ch, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk });
          await new Promise((r) => setTimeout(r, 20));
        }
        console.log(JSON.stringify({ ok: true, mode: 'keys', chars: text.length }));
      } else {
        await c.send('Input.insertText', { text });
        console.log(JSON.stringify({ ok: true, mode: 'insertText', chars: text.length, note: 'insertText 不产生 keydown/keyup；需要事件序列时加 --keys' }));
      }
    } else if (cmd === 'shot') {
      const r = await c.send('Page.captureScreenshot', { format: 'png' });
      const p = val('path', '/tmp/shot.png');
      fs.writeFileSync(p, Buffer.from(r.data, 'base64'));
      console.log(JSON.stringify({ ok: true, path: p, bytes: Buffer.from(r.data, 'base64').length }));
    } else {
      console.error('usage: driver.js --cdp URL {scan|goto|eval|click|type|shot} ...');
      process.exitCode = 2;
    }
  } finally { c.close(); }
})().catch((e) => { console.error('ERR', e.message); process.exit(2); });
