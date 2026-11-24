#!/usr/bin/env node
/* ============================================================================
 * farm.mjs — 自建浏览器农场（不依赖紫鸟生态）
 *
 * 设计要点（每条都有实测依据）：
 *   1. 只开 --remote-debugging-port，**不加 --enable-automation**
 *      → 实测 navigator.webdriver 原生就是 false，无需任何 JS 补丁；
 *   2. 每个账号独立 --user-data-dir + 独立端口 + 独立代理；
 *   3. 时区走进程 env TZ、语言走 --lang/--accept-lang（native 生效，不动 JS）；
 *   4. 代理走本地桥（proxy-bridge.js）→ 上游 SOCKS5 认证；
 *   5. 不做 canvas/webgl 注入：一机多 profile 会共享 GPU 指纹，要隔离就一账号一 VM。
 *
 * 用法：
 *   node farm.mjs start --account acc01 --port 19401 --tz Asia/Tokyo --lang ja-JP
 *   node farm.mjs start --account acc02 --port 19402 --tz America/New_York --lang en-US \
 *        --proxy http://127.0.0.1:18080 --headless
 *   node farm.mjs check --account acc01        # 或 --all
 *   node farm.mjs list
 *   node farm.mjs stop --account acc01 | --all
 * ========================================================================== */
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');
const WebSocket = require('ws');
let ledger = null;
try { ledger = require('./ledger'); } catch (e) { /* 台账不可用不影响启动 */ }

const CHROME = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// 引擎路由：不同流程用不同内核（指纹 / Google 服务 / Firefox 深人设）
const ENGINES = {
  chromium: process.env.FP_CHROME_BIN || '/Applications/fingerprint-chromium.app/Contents/MacOS/Chromium',
  chrome: CHROME,
  camoufox: process.env.CAMOUFOX_BIN || '',   // 由 worker 启动，见 camoufox_worker.py
};
const ROOT = path.resolve(__dirname);
const STATE = path.join(ROOT, 'state');
const PROFILES = path.join(ROOT, 'profiles');
fs.mkdirSync(STATE, { recursive: true });
fs.mkdirSync(PROFILES, { recursive: true });

const argv = process.argv.slice(2);
const cmd = argv[0];
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const has = (k) => argv.includes('--' + k);
const statePath = (a) => path.join(STATE, a + '.json');
/* profile 目录按平台分区：profiles/<platform>/<account>
 * 平台段做字符净化（不许 .. 或路径分隔符穿透），账号段保持原样（历史目录名带 ':'，改了会丢 Cookie）。
 * 未声明 platform 的账号落 profiles/_unsorted/，与「已分平台」的池子分开，避免同机混装时指纹串用。 */
const safeSeg = (s) => String(s).replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').replace(/^\.+$/, '_') || '_unsorted';
const profileDirFor = (account, platform) => path.join(PROFILES, platform ? safeSeg(platform) : '_unsorted', account);

/* ---------- 工具 ---------- */
const getJSON = (url, timeout = 3000) => new Promise((resolve, reject) => {
  const req = http.get(url, { timeout }, (res) => {
    let b = ''; res.setEncoding('utf8');
    res.on('data', (c) => (b += c));
    res.on('end', () => { try { resolve(JSON.parse(b)); } catch (e) { reject(new Error('bad json')); } });
  });
  req.on('timeout', () => req.destroy(new Error('timeout')));
  req.on('error', reject);
});

async function cdp(baseOrPort) {
  const base = String(baseOrPort).startsWith('http') ? String(baseOrPort).replace(/\/$/, '') : `http://127.0.0.1:${baseOrPort}`;
  const list = await getJSON(`${base}/json/list`);
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
    const timer = setTimeout(() => { if (pending.has(i)) { pending.delete(i); rej(new Error(method + ' timeout')); } }, 15000);
    pending.set(i, { res: (v) => { clearTimeout(timer); res(v); }, rej: (e) => { clearTimeout(timer); rej(e); } });
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  const evalJS = async (expr) => {
    const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text || 'eval error');
    return r.result.value;
  };
  return { send, evalJS, close: () => ws.close() };
}

/* ---------- start ---------- */
async function start() {
  const account = val('account');
  const port = parseInt(val('port', '0'), 10);
  if (!account || !port) { console.error('need --account and --port'); process.exit(2); }
  if (fs.existsSync(statePath(account))) {
    const s = JSON.parse(fs.readFileSync(statePath(account), 'utf8'));
    try { process.kill(s.pid, 0); console.error(`account ${account} already running (pid ${s.pid}, port ${s.port})`); process.exit(3); } catch (e) {}
  }
  const platform = val('platform', '');
  const profile = val('profile', profileDirFor(account, platform));
  fs.mkdirSync(profile, { recursive: true });

  const tz = val('tz', 'Asia/Shanghai');
  const lang = val('lang', 'zh-CN');
  const proxy = val('proxy', '');
  const headless = has('headless');
  const extra = val('extra', '');            // 额外 Chrome 参数，空格分隔
  const fpSeed = val('fp-seed', '');         // 内核指纹种子 → --fingerprint=<seed>
  const engine = val('engine', 'chromium');
  if (!ENGINES[engine] && engine !== 'camoufox' && !val('chrome', '')) {
    console.error(`unknown engine '${engine}' (chromium|chrome|camoufox)；也可用 --chrome 直接指定二进制`);
    process.exit(2);
  }
  const chromeBin = val('chrome', ENGINES[engine]);
  if (engine === 'camoufox') {
    // worker 引擎：不起进程、不暴露 CDP，只登记台账与 state；任务由 gateway 调 camoufox_worker.py 执行
    const rec = {
      account, pid: null, port: null, tz, lang, proxy, headless: true, extra, profile,
      platform: platform || null, engine: 'camoufox', mode: 'worker', cdp: null,
      startedAt: new Date().toISOString(),
    };
    fs.writeFileSync(statePath(account), JSON.stringify(rec, null, 2));
    try {
      if (ledger) ledger.upsertAccount({ account, store_id: val('store', null), platform: val('platform', null),
        port: null, proxy: proxy || null, tz, lang, extra: extra || null, profile, headless: 1,
        fp_seed: fpSeed || null, engine, cdp: null, pid: null, status: 'running' });
    } catch (e) { console.error('ledger warn:', e.message); }
    console.log(JSON.stringify({ ok: true, account, engine: 'camoufox', mode: 'worker', cdp: null,
      profile, tz, lang, note: 'worker 引擎：任务走 camoufox_worker.py，无 CDP 端点' }, null, 2));
    return;
  }

  const args = [
    `--user-data-dir=${profile}`,
    `--remote-debugging-port=${port}`,
    '--remote-debugging-address=127.0.0.1',
    '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--disable-sync', '--disable-default-apps',
    `--lang=${lang}`, `--accept-lang=${lang}`,
    '--window-size=1440,900',
  ];
  if (proxy) args.unshift(`--proxy-server=${proxy}`);
  if (fpSeed) args.push(`--fingerprint=${fpSeed}`);
  if (extra) args.push(...extra.split(/\s+/).filter(Boolean));
  if (headless) args.unshift('--headless=new');
  args.push('about:blank');

  const child = spawn(chromeBin, args, {
    detached: true, stdio: 'ignore',
    env: Object.assign({}, process.env, { TZ: tz }),
  });
  child.unref();

  const rec = { account, pid: child.pid, port, tz, lang, proxy, headless, extra, profile, platform: platform || null, startedAt: new Date().toISOString() };
  fs.writeFileSync(statePath(account), JSON.stringify(rec, null, 2));

  // 等就绪
  let ready = null;
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 500));
    try { ready = await getJSON(`http://127.0.0.1:${port}/json/version`); break; } catch (e) {}
  }
  if (!ready) { console.error(JSON.stringify({ ok: false, error: 'cdp not ready', port })); process.exit(4); }
  try {
    if (ledger) ledger.upsertAccount({ account, store_id: val('store', null), platform: val('platform', null),
      port, proxy: proxy || null, tz, lang, extra: extra || null, profile, headless: headless ? 1 : 0,
      fp_seed: fpSeed || null, engine, cdp: `http://127.0.0.1:${port}`,
      pid: child.pid, status: 'running' });
  } catch (e) { console.error('ledger warn:', e.message); }
  console.log(JSON.stringify({ ok: true, account, pid: child.pid, port, cdp: `http://127.0.0.1:${port}`, browser: ready.Browser, tz, lang, proxy: proxy || '(direct)' }, null, 2));
}

/* ---------- check ---------- */
const PROBE = (noIp) => `(async () => {
  const __NO_IP__ = ${noIp};
  const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16).padStart(8, '0'); };
  const draw = () => { const c = document.createElement('canvas'); c.width = 240; c.height = 60; const x = c.getContext('2d');
    x.textBaseline = 'top'; x.font = "14px 'Arial'"; x.fillStyle = '#f60'; x.fillRect(100, 1, 62, 20);
    x.fillStyle = '#069'; x.fillText('farm-probe-🔍', 2, 15); return c.toDataURL(); };
  const a = draw(), b = draw();
  const gl = document.createElement('canvas').getContext('webgl');
  const dbg = gl && gl.getExtension('WEBGL_debug_renderer_info');
  let ip = null, ipErr = null;
  if (__NO_IP__) { ip = 'skipped'; } else
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 3000);
    const url = globalThis.__FARM_IP_ECHO__ || 'https://api.ipify.org?format=json';
    const r = await fetch(url, { cache: 'no-store', signal: ctl.signal });
    ip = (await r.json()).ip; clearTimeout(t);
  } catch (e) { ipErr = e.name === 'AbortError' ? 'timeout(3s)' : e.message; }
  return {
    webdriver: navigator.webdriver,
    ua: navigator.userAgent,
    lang: navigator.language, languages: navigator.languages,
    tz: Intl.DateTimeFormat().resolvedOptions().timeZone, tzOffsetMin: new Date().getTimezoneOffset(),
    canvas: { hash: fnv(a), stable: a === b },
    webgl: gl ? { vendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
                  renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
                  maxTex: gl.getParameter(gl.MAX_TEXTURE_SIZE), exts: (gl.getSupportedExtensions()||[]).length } : null,
    plugins: navigator.plugins.length,
    hc: navigator.hardwareConcurrency, dm: navigator.deviceMemory ?? null,
    integrity: Function.prototype.toString.call(HTMLCanvasElement.prototype.toDataURL),
    ip, ipErr
  };
})()`;

/* ---------- worker 通道（camoufox，无 CDP）---------- */
const CAMOUFOX_PY = process.env.CAMOUFOX_PY || 'python3';
const CAMOUFOX_WORKER = path.join(ROOT, 'camoufox_worker.py');

function runWorker(rec, task, timeout = 180000) {
  return new Promise((resolve, reject) => {
    const args = [CAMOUFOX_WORKER, '--account', String(rec.account), '--profile', String(rec.profile || ''),
      '--tz', rec.tz || 'Asia/Shanghai', '--lang', rec.lang || 'zh-CN', '--task', '-'];
    if (rec.headless !== false) args.push('--headless');
    if (rec.proxy) args.push('--proxy', rec.proxy);
    const p = spawn(CAMOUFOX_PY, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', err = '';
    const timer = setTimeout(() => { try { p.kill('SIGKILL'); } catch (e) {} reject(new Error('worker timeout ' + timeout + 'ms')); }, timeout);
    p.stdout.on('data', (c) => (out += c));
    p.stderr.on('data', (c) => (err += c));
    p.on('error', (e) => { clearTimeout(timer); reject(e); });
    p.on('close', () => {
      clearTimeout(timer);
      const line = out.trim().split('\n').filter(Boolean).pop();
      let j = null; try { j = JSON.parse(line); } catch (e) {}
      if (!j) return reject(new Error('worker 无结构化输出: ' + (err || out).trim().slice(0, 300)));
      if (j.ok === false) return reject(new Error(j.error || 'worker failed'));
      resolve(j);
    });
    p.stdin.end(JSON.stringify(task));
  });
}

async function camoufoxScan(rec) {
  const j = await runWorker(rec, { type: 'scan', params: { no_ip: has('no-ip') } }, 180000);
  const p = (j.result && j.result.probe) || {};
  return {
    webdriver: p.webdriver, ua: p.ua,
    lang: p.language, languages: p.languages, tz: p.tz,
    canvas: p.canvas, webgl: p.webgl, plugins: p.plugins,
    hc: p.hc, dm: p.dm, fonts: p.fonts,
    integrity: p.toDataURL,
    ip: p.ip, ipErr: p.ipErr,
    engine: 'camoufox',
  };
}

async function cdpScan(rec) {
  const c = await cdp(rec.cdp || rec.port);
  try {
    await c.evalJS('globalThis.__FARM_IP_ECHO__=' + JSON.stringify(process.env.FARM_IP_ECHO || 'https://api.ipify.org?format=json'));
    return await c.evalJS(PROBE(has('no-ip')));
  } finally { c.close(); }
}

/* 体检判据：两个通道共用同一套，保证「同形」不是只在返回形状上 */
function judge(rec, d) {
  const fails = [];
  if (d.webdriver !== false) fails.push('webdriver=' + d.webdriver);
  if (d.tz !== rec.tz) fails.push(`tz ${d.tz} != ${rec.tz}`);
  if (!(d.languages || []).some((l) => l.toLowerCase().startsWith(String(rec.lang).toLowerCase().split('-')[0]))) fails.push('lang ' + d.languages);
  if (!(d.canvas || {}).stable) fails.push('canvas unstable');
  if (!/\[native code\]/.test(d.integrity)) fails.push('toString hooked');
  return fails;
}

async function check() {
  const all = has('all');
  const accounts = all ? fs.readdirSync(STATE).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)) : [val('account')];
  const out = [];
  for (const a of accounts) {
    if (!a) continue;
    const sp = statePath(a);
    if (!fs.existsSync(sp)) { out.push({ account: a, ok: false, error: 'no state' }); continue; }
    const rec = JSON.parse(fs.readFileSync(sp, 'utf8'));
    try {
      const d = (rec.engine === 'camoufox' || rec.mode === 'worker') ? await camoufoxScan(rec) : await cdpScan(rec);
      const fails = judge(rec, d);
      const item = { account: a, ok: fails.length === 0, port: rec.port, fails, probe: d };
      try { if (ledger) ledger.recordCheck(a, item); } catch (e) {}
      out.push(item);
    } catch (e) {
      out.push({ account: a, ok: false, port: rec.port, error: e.message });
    }
  }
  console.log(JSON.stringify(out, null, 2));
  process.exitCode = out.every((x) => x.ok) ? 0 : 1;
}

/* ---------- list / stop ---------- */
function list() {
  const rows = fs.readdirSync(STATE).filter((f) => f.endsWith('.json')).map((f) => {
    const r = JSON.parse(fs.readFileSync(path.join(STATE, f), 'utf8'));
    let alive = false; try { process.kill(r.pid, 0); alive = true; } catch (e) {}
    return { account: r.account, pid: r.pid, port: r.port, alive, tz: r.tz, lang: r.lang, proxy: r.proxy || '(direct)', headless: !!r.headless };
  });
  console.log(JSON.stringify(rows, null, 2));
}

async function attach() {
  const account = val('account');
  const cdpUrl = val('cdp');
  if (!account || !cdpUrl) { console.error('need --account and --cdp'); process.exit(2); }
  const u = new URL(cdpUrl);
  const ver = await getJSON(`${cdpUrl.replace(/\/$/, '')}/json/version`);
  const rec = {
    account, cdp: cdpUrl.replace(/\/$/, ''), port: Number(u.port || 80), host: u.hostname,
    tz: val('tz', 'Asia/Shanghai'), lang: val('lang', 'zh-CN'), proxy: null, extra: null,
    profile: null, headless: 1, fp_seed: val('seed', null), engine: val('engine', 'external'),
    platform: val('platform', null),
    attached: true, pid: null, startedAt: new Date().toISOString(),
  };
  fs.writeFileSync(statePath(account), JSON.stringify(rec, null, 2));
  try { if (ledger) ledger.upsertAccount({ ...rec, status: 'running' }); } catch (e) {}
  console.log(JSON.stringify({ ok: true, attached: account, cdp: rec.cdp, browser: ver.Browser, engine: rec.engine }, null, 2));
}

function dup() {
  // 每个账号取最后一次体检的 canvas hash，找出撞车的分组
  const rows = ledger.db.prepare(`
    SELECT canvas, COUNT(*) n, GROUP_CONCAT(account) accts
    FROM checks WHERE id IN (SELECT MAX(id) FROM checks GROUP BY account)
      AND canvas IS NOT NULL
    GROUP BY canvas HAVING n > 1
  `).all();
  const uniq = ledger.db.prepare(`
    SELECT COUNT(DISTINCT canvas) n FROM checks
    WHERE id IN (SELECT MAX(id) FROM checks GROUP BY account) AND canvas IS NOT NULL
  `).get().n;
  console.log(JSON.stringify({ distinct_canvas: uniq, collisions: rows }, null, 2));
  process.exitCode = rows.length ? 1 : 0;
}

function stop() {
  const all = has('all');
  const accounts = all ? fs.readdirSync(STATE).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)) : [val('account')];
  for (const a of accounts) {
    if (!a) continue;
    const sp = statePath(a);
    if (!fs.existsSync(sp)) continue;
    const r = JSON.parse(fs.readFileSync(sp, 'utf8'));
    if (r.pid) {
      try { process.kill(-r.pid, 'SIGTERM'); } catch (e) { try { process.kill(r.pid, 'SIGTERM'); } catch (e2) {} }
    }
    fs.unlinkSync(sp);
    try { if (ledger) ledger.setStatus(a, 'stopped', null); } catch (e) {}
    console.log('stopped', a, 'pid', r.pid);
  }
}

(async () => {
  switch (cmd) {
    case 'start': await start(); break;
    case 'check': await check(); break;
    case 'list': list(); break;
    case 'attach': await attach(); break;
    case 'dup': dup(); break;
    case 'stop': stop(); break;
    default: console.error('usage: farm.mjs {start|check|list|stop} ...'); process.exit(2);
  }
})().catch((e) => { console.error('ERR', e.message); process.exit(2); });
