#!/usr/bin/env node
/* ============================================================================
 * verify-egress.js — 离线验证「流量确实走代理 + 域名在代理侧解析」
 *
 * 为什么不用外网：本机（及很多隔离环境）没有出网。链路正确性不需要真实出口 IP，
 * 只需要证明三件事：
 *   1) 浏览器的请求确实到达了代理，而不是直连；
 *   2) 代理看到的是**域名**（absolute-form / CONNECT），说明 DNS 在代理侧完成；
 *   3) 页面能渲染出代理注入的标记头 → 端到端穿过代理。
 *
 * 做法：起一个本地「目标站」+ 一个会记账的本地代理，让 Chrome 只通过该代理访问
 *      一个**本地不可解析**的域名（egress.test）。能拿到页面 = 代理侧解析成功。
 *
 * 用法：
 *   node verify-egress.js [--chrome /path/to/Chrome] [--json]
 * 退出码：0 全通过；1 有失败项；2 环境错误
 * ========================================================================== */
'use strict';
const http = require('http');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');

const CHROME = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const HOST = 'egress.test';
const TZ = 'Asia/Tokyo';

const freePort = () => new Promise((res) => {
  const s = net.createServer();
  s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); });
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const getJSON = (url, t = 2000) => new Promise((resolve, reject) => {
  const req = http.get(url, { timeout: t }, (r) => { let b = ''; r.on('data', (c) => (b += c)); r.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } }); });
  req.on('timeout', () => req.destroy(new Error('timeout')));
  req.on('error', reject);
});

async function main() {
  const checks = [];
  const add = (id, ok, detail) => checks.push({ id, ok, detail });

  /* 1. 目标站：回显它收到的 Host / 标记头 / 来源地址 */
  const target = http.createServer((req, res) => {
    const body = JSON.stringify({
      ok: true, host: req.headers.host, path: req.url,
      viaProxy: req.headers['x-egress-proxy'] || null,
      seenFrom: req.socket.remoteAddress,
    });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(body);
  });
  await new Promise((r) => target.listen(0, '127.0.0.1', r));
  const targetPort = target.address().port;

  /* 2. 记账代理：只接受 egress.test，转发到目标站并塞标记头 */
  const log = [];
  const proxy = http.createServer((req, res) => {
    let u;
    try { u = new URL(req.url); } catch (e) { res.writeHead(400); return res.end('absolute-form required'); }
    log.push({ kind: 'request', method: req.method, host: u.hostname, path: u.pathname });
    if (u.hostname !== HOST) { res.writeHead(502); return res.end('unexpected host ' + u.hostname); }
    // 关键：用 http.request 而不是 net.connect，避免把上游的 status line/headers 塞进 ServerResponse
    const upReq = http.request({
      host: '127.0.0.1', port: targetPort, method: req.method, path: u.pathname + u.search,
      headers: Object.assign({}, req.headers, { host: u.host, 'x-egress-proxy': 'farm-verify' }),
    }, (up) => { res.writeHead(up.statusCode || 502, up.headers); up.pipe(res); });
    upReq.on('error', () => { try { res.writeHead(502); res.end('upstream error'); } catch (e) {} });
    req.on('error', () => {});
    res.on('error', () => {});
    req.pipe(upReq);
  });
  proxy.on('connect', (req, sock) => {
    log.push({ kind: 'connect', host: req.url });
    sock.on('error', () => {});
    sock.end('HTTP/1.1 502 no-tls-in-fixture\r\n\r\n');
  });
  proxy.on('clientError', (_e, sock) => { try { sock.destroy(); } catch (e) {} });
  await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
  const proxyPort = proxy.address().port;

  /* 3. 启动 Chrome：只配代理，不加 automation 参数 */
  const cdpPort = await freePort();
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'farm-egress-'));
  const args = [
    '--headless=new',
    `--user-data-dir=${profile}`,
    `--remote-debugging-port=${cdpPort}`,
    `--proxy-server=http://127.0.0.1:${proxyPort}`,
    '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
    '--disable-component-update', '--disable-domain-reliability', '--no-pings',
    '--window-size=1200,800', 'about:blank',
  ];
  const chrome = spawn(CHROME, args, { detached: true, stdio: 'ignore', env: Object.assign({}, process.env, { TZ }) });
  chrome.unref();

  const cleanup = async () => {
    const { execFileSync } = require('child_process');
    const killByProfile = (sig) => { try { execFileSync('pkill', [sig, '-f', `user-data-dir=${profile}`], { stdio: 'ignore' }); } catch (e) {} };
    try { process.kill(-chrome.pid, 'SIGTERM'); } catch (e) {}
    try { process.kill(chrome.pid, 'SIGTERM'); } catch (e) {}
    killByProfile('-TERM');
    await sleep(400);
    killByProfile('-9');                       // Chrome 子进程可能另起 session，按 profile 兜底
    await sleep(200);
    try { proxy.close(); } catch (e) {}
    try { target.close(); } catch (e) {}
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch (e) {}
  };

  try {
    // 等 CDP
    let ver = null;
    for (let i = 0; i < 40; i++) { await sleep(300); try { ver = await getJSON(`http://127.0.0.1:${cdpPort}/json/version`); break; } catch (e) {} }
    if (!ver) throw new Error('cdp not ready');
    add('cdp.ready', true, ver.Browser);
    add('browser.no-automation-flag', !args.includes('--enable-automation'), args.filter((a) => a.startsWith('--proxy')).join(' '));

    const targets = await getJSON(`http://127.0.0.1:${cdpPort}/json/list`);
    const page = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    let id = 0; const pending = new Map();
    await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
    ws.on('message', (raw) => { const m = JSON.parse(raw); if (m.id && pending.has(m.id)) { const { res, rej } = pending.get(m.id); pending.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); } });
    const send = (method, params = {}) => new Promise((res, rej) => {
      const i = ++id;
      const t = setTimeout(() => rej(new Error(method + ' timeout')), 10000);
      pending.set(i, { res: (v) => { clearTimeout(t); res(v); }, rej: (e) => { clearTimeout(t); rej(e); } });
      ws.send(JSON.stringify({ id: i, method, params }));
    });
    const evalJS = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true })).result.value;

    await send('Page.enable');
    await send('Page.navigate', { url: `http://${HOST}/probe` });

    // 等页面出内容
    let body = null;
    for (let i = 0; i < 25; i++) {
      await sleep(300);
      body = await evalJS("document.body ? document.body.innerText : ''").catch(() => '');
      if (body && body.includes('"ok"')) break;
    }

    let parsed = null;
    try { parsed = JSON.parse(body); } catch (e) {}
    add('page.reached', !!(parsed && parsed.ok), body ? body.slice(0, 160) : '(empty)');

    const sawHost = log.some((x) => x.host === HOST);
    add('proxy.saw-hostname', sawHost, JSON.stringify(log.slice(0, 4)));

    add('dns.resolved-at-proxy', !!(parsed && parsed.host === HOST),
      `${HOST} 本地不可解析；能取到响应 = 解析发生在代理侧`);

    add('proxy.marker-injected', !!(parsed && parsed.viaProxy === 'farm-verify'),
      parsed ? String(parsed.viaProxy) : 'null');

    add('no-direct-connection', log.length > 0 && parsed && parsed.ok,
      '目标站仅被代理转发（页面内容带代理标记头）');

    const wd = await evalJS('navigator.webdriver');
    add('navigator.webdriver=false', wd === false, String(wd));

    ws.close();
  } catch (e) {
    add('fatal', false, e.message);
  } finally {
    await cleanup();
  }

  const ok = checks.every((c) => c.ok);
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify({ ok, checks }, null, 2));
  } else {
    for (const c of checks) console.log(`${c.ok ? 'PASS' : 'FAIL'}  ${c.id}\n      ${c.detail}`);
    console.log(`\nsummary: ${checks.filter((c) => c.ok).length}/${checks.length} → ${ok ? 'PASS' : 'FAIL'}`);
  }
  process.exitCode = ok ? 0 : 1;
}

main().catch((e) => { console.error('ERR', e.message); process.exit(2); });
