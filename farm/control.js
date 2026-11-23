#!/usr/bin/env node
/* ============================================================================
 * control.js — 农场控制面（给 DS-Bot 调用的本地 HTTP API）
 *
 * 只绑 127.0.0.1；可选 --token 做头校验（x-farm-token）。
 * 所有写操作都经过 farm.js / ledger.js，保证 CLI 与 API 两条路径行为一致。
 *
 * 路由：
 *   GET    /health                        → 台账统计 + 进程存活数
 *   GET    /instances                     → 账号列表（含 alive / 最近体检）
 *   POST   /instances                     → 启动实例（端口可省略，自动分配）
 *          body: {account, tz, lang, proxy?, headless?, extra?, port?, store_id?, platform?}
 *   GET    /instances/:account            → 详情 + 最近 5 次体检
 *   GET    /instances/:account/history    → 体检历史（?limit=20）
 *   POST   /instances/:account/check      → 立即体检并落库
 *   DELETE /instances/:account            → 停止并标记 stopped
 *
 * 用法：
 *   node control.js --port 19555 [--token [TOKEN]] [--range 19400-19499]
 * ========================================================================== */
'use strict';
const http = require('http');
const net = require('net');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const ledger = require('./ledger');

const exec = promisify(execFile);
const FARM = path.join(__dirname, 'farm.js');

const argv = process.argv.slice(2);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const PORT = parseInt(val('port', '19555'), 10);
const TOKEN = val('token', process.env.FARM_TOKEN || '');
const [R0, R1] = (val('range', '19400-19499')).split('-').map((x) => parseInt(x, 10));

const send = (res, code, obj) => {
  const body = JSON.stringify(obj, null, 2);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
};

function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = ''; let n = 0;
    req.on('data', (c) => { n += c.length; if (n > 65536) { reject(new Error('body too large')); req.destroy(); } b += c; });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { reject(new Error('bad json')); } });
    req.on('error', reject);
  });
}

/* 端口分配：先试 bind，成功即空闲 */
function portFree(p) {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.once('error', () => resolve(false));
    s.once('listening', () => s.close(() => resolve(true)));
    s.listen(p, '127.0.0.1');
  });
}
async function allocPort(want) {
  if (want) {
    if (await portFree(want)) return want;
    throw new Error(`port ${want} in use`);
  }
  const used = new Set(ledger.list().filter((r) => r.alive).map((r) => r.port));
  for (let p = R0; p <= R1; p++) if (!used.has(p) && (await portFree(p))) return p;
  throw new Error('no free port in range');
}

function runFarm(args, timeout = 90000) {
  return exec('node', [FARM, ...args], { timeout, maxBuffer: 4 * 1024 * 1024 })
    .then(({ stdout, stderr }) => ({ ok: true, out: parseJSON(stdout), stderr }))
    .catch((e) => ({ ok: false, error: (e.stderr || e.message || '').toString().slice(0, 800), out: parseJSON(e.stdout || '') }));
}
function parseJSON(s) {
  if (!s || !s.trim()) return null;
  try { return JSON.parse(s); } catch (e) {
    const i = s.search(/[[{]/); if (i < 0) return null;
    try { return JSON.parse(s.slice(i)); } catch (e2) { return null; }
  }
}

const server = http.createServer(async (req, res) => {
  try {
    if (TOKEN && req.headers['x-farm-token'] !== TOKEN) return send(res, 401, { ok: false, error: 'bad token' });
    const url = new URL(req.url, 'http://127.0.0.1');
    const parts = url.pathname.split('/').filter(Boolean);
    const method = req.method;

    if (method === 'GET' && url.pathname === '/health') {
      const s = ledger.stats();
      const alive = ledger.list().filter((r) => r.alive).length;
      return send(res, 200, { ok: true, service: 'farm-control', ...s, alive });
    }

    if (method === 'GET' && url.pathname === '/instances') {
      const pf = url.searchParams.get('platform');
      const all = ledger.list();
      return send(res, 200, { ok: true, platform: pf || null, instances: pf ? all.filter((r) => r.platform === pf) : all });
    }

    if (method === 'POST' && url.pathname === '/instances') {
      const b = await readBody(req);
      if (!b.account) return send(res, 400, { ok: false, error: 'account required' });
      if (ledger.getAccount(b.account) && ledger.getAccount(b.account).alive) {
        return send(res, 409, { ok: false, error: 'already running', account: ledger.getAccount(b.account) });
      }
      const port = await allocPort(b.port);
      const args = ['start', '--account', b.account, '--port', String(port),
        '--tz', b.tz || 'Asia/Shanghai', '--lang', b.lang || 'zh-CN',
        '--engine', b.engine || 'chromium'];
      if (b.proxy) args.push('--proxy', b.proxy);
      if (b.headless) args.push('--headless');
      if (b.fp_seed) args.push('--fp-seed', String(b.fp_seed));
      if (b.chrome) args.push('--chrome', b.chrome);
      if (b.extra) args.push('--extra', b.extra);
      if (b.store_id) args.push('--store', String(b.store_id));
      if (b.platform) args.push('--platform', String(b.platform));
      const r = await runFarm(args);
      if (!r.ok) return send(res, 500, { ok: false, error: r.error, raw: r.out });
      return send(res, 201, { ok: true, instance: r.out, ledger: ledger.getAccount(b.account) });
    }

    if (method === 'POST' && url.pathname === '/instances/attach') {
      const b = await readBody(req);
      if (!b.account || !b.cdp) return send(res, 400, { ok: false, error: 'account and cdp required' });
      const args = ['attach', '--account', b.account, '--cdp', b.cdp,
        '--engine', b.engine || 'external', '--tz', b.tz || 'Asia/Shanghai', '--lang', b.lang || 'zh-CN'];
      if (b.seed) args.push('--seed', String(b.seed));
      if (b.platform) args.push('--platform', String(b.platform));
      const r = await runFarm(args, 20000);
      if (!r.ok) return send(res, 502, { ok: false, error: r.error, raw: r.out });
      return send(res, 201, { ok: true, instance: r.out, ledger: ledger.getAccount(b.account) });
    }

    if (parts[0] === 'instances' && parts[1]) {
      const account = decodeURIComponent(parts[1]);
      const rec = ledger.getAccount(account);

      if (method === 'GET' && parts[2] === 'history') {
        const limit = parseInt(url.searchParams.get('limit') || '20', 10);
        return send(res, 200, { ok: true, account, history: ledger.history(account, limit) });
      }

      if (method === 'GET' && parts.length === 2) {
        if (!rec) return send(res, 404, { ok: false, error: 'not found' });
        return send(res, 200, { ok: true, instance: Object.assign({}, rec, { alive: ledger.alive(rec.pid) }), history: ledger.history(account, 5) });
      }

      if (method === 'POST' && parts[2] === 'check') {
        if (!rec) return send(res, 404, { ok: false, error: 'not found' });
        const fast = url.searchParams.get('ip') !== '1';
        const r = await runFarm(['check', '--account', account].concat(fast ? ['--no-ip'] : []), 60000);
        if (!r.ok) return send(res, 500, { ok: false, error: r.error });
        const item = Array.isArray(r.out) ? r.out.find((x) => x.account === account) : r.out;
        return send(res, item && item.ok ? 200 : 424, { ok: !!(item && item.ok), check: item });
      }

      if (method === 'DELETE' && parts.length === 2) {
        if (!rec) return send(res, 404, { ok: false, error: 'not found' });
        const r = await runFarm(['stop', '--account', account], 30000);
        return send(res, r.ok ? 200 : 500, { ok: r.ok, account, status: 'stopped', raw: r.out, error: r.error });
      }
    }

    return send(res, 404, { ok: false, error: 'no route', path: url.pathname, method });
  } catch (e) {
    return send(res, 500, { ok: false, error: e.message });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(JSON.stringify({ ok: true, service: 'farm-control', url: `http://127.0.0.1:${PORT}`, token: TOKEN ? '(required)' : '(none)', range: [R0, R1], db: ledger.stats().db }, null, 2));
});
