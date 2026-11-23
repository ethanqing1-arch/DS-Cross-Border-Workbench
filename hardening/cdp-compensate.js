#!/usr/bin/env node
/* ============================================================================
 * cdp-compensate.js — 通过 CDP 注入 can_webdriver 补偿载荷，并自检覆盖范围
 *
 * 用法：
 *   node cdp-compensate.js --cdp http://127.0.0.1:PORT --install
 *        → Page.addScriptToEvaluateOnNewDocument，返回 identifier
 *   node cdp-compensate.js --cdp http://127.0.0.1:PORT --install --reload
 *        → 安装后立即 reload，使载荷在每个新文档/每个 frame 生效
 *   node cdp-compensate.js --cdp http://127.0.0.1:PORT --selftest
 *        → 读主 Realm / iframe Realm / toString 完整性，判断覆盖是否完整
 *   node cdp-compensate.js --cdp http://127.0.0.1:PORT --remove <identifier>
 *
 * 依赖：ws（工作区 node_modules 已有；无需 playwright/puppeteer）
 * ========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const WebSocket = require('ws');

/* ---------- 参数 ---------- */
const argv = process.argv.slice(2);
const has = (k) => argv.includes('--' + k);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const CDP = val('cdp', 'http://127.0.0.1:19222').replace(/\/$/, '');
const FILE = val('file', path.join(__dirname, 'inject-webdriver.js'));

/* ---------- HTTP: 取 target ---------- */
function getJSON(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 5000 }, (res) => {
      let b = ''; res.setEncoding('utf8');
      res.on('data', (c) => (b += c));
      res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(new Error('bad json: ' + b.slice(0, 120))); } });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

/* ---------- 极简 CDP 客户端 ---------- */
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
      const timer = setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); rej(new Error(method + ' timeout')); } }, 15000);
      this.pending.set(id, { res: (v) => { clearTimeout(timer); res(v); }, rej: (e) => { clearTimeout(timer); rej(e); } });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() { try { this.ws.close(); } catch (e) {} }
}

const EVAL = `(() => {
  const out = { mainRealm: navigator.webdriver, ts: Function.prototype.toString.call(Function.prototype.toString) };
  try {
    const f = document.createElement('iframe'); f.style.display='none'; document.body.appendChild(f);
    out.iframeRealm = f.contentWindow.navigator.webdriver; f.remove();
  } catch (e) { out.iframeRealm = 'ERR ' + e.message; }
  out.patched = !!window.__WD_PATCHED__;
  return out;
})()`;

(async () => {
  const list = await getJSON(CDP + '/json/list');
  const page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  if (!page) throw new Error('no page target at ' + CDP);
  const c = await new CDPClient(page.webSocketDebuggerUrl).open();

  try {
    if (has('remove')) {
      const id = val('remove');
      await c.send('Page.removeScriptToEvaluateOnNewDocument', { identifier: id });
      console.log(JSON.stringify({ ok: true, removed: id }));
      return;
    }

    if (has('selftest') && !has('install')) {
      const r = await c.send('Runtime.evaluate', { expression: EVAL, returnByValue: true });
      const v = r.result && r.result.value || {};
      const complete = v.mainRealm === false && v.iframeRealm === false;
      console.log(JSON.stringify({
        ok: true, selftest: v,
        verdict: complete ? 'COVERED（主 Realm + iframe 均已补偿）'
                          : 'LEAK（存在未覆盖 Realm：iframe=' + v.iframeRealm + '，跨 Realm 比对即可识破）',
      }, null, 2));
      process.exitCode = complete ? 0 : 3;
      return;
    }

    // 默认：install
    const source = fs.readFileSync(FILE, 'utf8');
    await c.send('Page.enable');                       // 部分 build 需要显式 enable 才跟踪导航
    const r = await c.send('Page.addScriptToEvaluateOnNewDocument', { source });
    const out = { ok: true, identifier: r.identifier, file: FILE, bytes: Buffer.byteLength(source) };

    if (has('reload') || has('once')) {
      // 用带随机参数的 navigate 触发一次真正的「新文档」，避免缓存命中旧文档
      const url = page.url.split('#')[0] + (page.url.includes('?') ? '&' : '?') + 'zn_cb=' + Date.now();
      await c.send('Page.navigate', { url });
      // 轮询 readyState，最多 5 s
      let ready = false;
      for (let i = 0; i < 25; i++) {
        await new Promise((r2) => setTimeout(r2, 200));
        try {
          const st = await c.send('Runtime.evaluate', { expression: 'document.readyState', returnByValue: true });
          if (st.result && st.result.value === 'complete') { ready = true; break; }
        } catch (e) { /* 导航中执行上下文被销毁，忽略 */ }
      }
      const s = await c.send('Runtime.evaluate', { expression: EVAL, returnByValue: true });
      out.readyState = ready ? 'complete' : 'timeout';
      out.after = s.result && s.result.value;
      out.verdict = (out.after && out.after.mainRealm === false && out.after.iframeRealm === false)
        ? 'COVERED' : 'LEAK';
      // 同一会话内再自检一次：用于对比「会话断开后」的覆盖退化
      if (has('selftest')) {
        const s2 = await c.send('Runtime.evaluate', { expression: EVAL, returnByValue: true });
        out.selftestSameSession = s2.result && s2.result.value;
      }
    }
    console.log(JSON.stringify(out, null, 2));
  } finally {
    c.close();
  }
})().catch((e) => {
  console.error('ERR:', e.message);
  process.exitCode = 2;
});
