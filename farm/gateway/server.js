#!/usr/bin/env node
/* ============================================================================
 * gateway/server.js — dsbot-gateway 参考实现（Node 标准库，无依赖）
 *
 * 定位：只做编排，不碰浏览器。
 *   会话生命周期 → 调 farm control（/instances、/instances/attach、check、删除）
 *   任务执行     → 调 driver.js（goto/eval/click/type/shot/scan）
 *   去重         → 调 `farm.js dup`（control 没有该路由）
 *
 * 用法：
 *   node gateway/server.js --port 19600 --control http://127.0.0.1:19555 \
 *        --farm /path/to/farm.js --driver /path/to/driver.js --token TOKEN
 *
 * 契约见 docs/dsbot-workbench-architecture.md 第三节。
 * ========================================================================== */
'use strict';
const http = require('http');
const { execFile, spawn } = require('child_process');
const { promisify } = require('util');
const path = require('path');
const crypto = require('crypto');
const exec = promisify(execFile);

const argv = process.argv.slice(2);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const PORT = parseInt(val('port', '19600'), 10);
const CONTROLS = String(val('controls', val('control', 'http://127.0.0.1:19555')))
  .split(',').map((x) => x.trim().replace(/\/$/, '')).filter(Boolean);
const CONTROL = CONTROLS[0];
const FARM = val('farm', path.join(__dirname, '..', 'farm.js'));
const DRIVER = val('driver', path.join(__dirname, '..', 'driver.js'));
const TOKEN = val('token', process.env.GATEWAY_TOKEN || '');
const CTRL_TOKEN = process.env.FARM_TOKEN || TOKEN;   // 调 control 用 control 面令牌；FARM_TOKEN 未设时保持旧行为
const QUOTA = parseInt(val('quota', '8'), 10);
const RPS = parseInt(val('rps', '50'), 10);

/* 引擎能力与任务类型从 contract.js 取（唯一事实源，避免网关与对外契约漂移） */
const { ENGINE_CAPS, ATTACH_ONLY: ATTACH_ONLY_LIST, VERSION, CONTRACT_VERSION, contract } = require('../contract');
const ATTACH_ONLY = new Set(ATTACH_ONLY_LIST);

const TASK_REGISTRY = {
  goto:  (p) => ['goto', '--url', String(p.url)],
  eval:  (p) => ['eval', '--expr', String(p.expr)],
  click: (p) => ['click', '--x', String(p.x), '--y', String(p.y)],
  type:  (p) => ['type', '--text', String(p.text)].concat(p.mode === 'keys' ? ['--keys'] : []),
  shot:  (p) => ['shot'].concat(p.path ? ['--path', String(p.path)] : []),
  scan:  () => ['scan'],
  // M1：结构化字段抽取 + 选择器等待，均走现有 CDP 通道，无新依赖
  extract: (p) => ['extract', '--selector-map', JSON.stringify(p.selector_map || {})]
    .concat(p.url ? ['--url', String(p.url)] : [])
    .concat(p.timeout_ms ? ['--timeout', String(p.timeout_ms)] : []),
  wait: (p) => ['wait', '--selector', String(p.selector), '--state', String(p.state || 'present'),
    '--timeout-ms', String(p.timeout_ms || 30000)],
};

/* M1：健康探针——真起一个临时实例跑一次 goto about:blank，再销毁 */
const PROBE_ENGINES = ['chromium', 'chrome'];

/* worker 任务通道（camoufox）：一次任务一个 worker 进程，无 CDP */
const CAMOUFOX_PY = val('camoufox-py', process.env.CAMOUFOX_PY || 'python3');
const CAMOUFOX_WORKER = val('camoufox-worker', path.join(__dirname, '..', 'camoufox_worker.py'));

function runWorkerTask(inst, type, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const profile = inst.profile || path.join(__dirname, '..', 'profiles', '_unsorted', String(inst.account));
    const args = [CAMOUFOX_WORKER, '--account', String(inst.account), '--profile', profile,
      '--tz', inst.tz || 'Asia/Shanghai', '--lang', inst.lang || 'zh-CN', '--task', '-'];
    if (inst.headless !== 0) args.push('--headless');
    if (inst.proxy) args.push('--proxy', String(inst.proxy));
    const p = spawn(CAMOUFOX_PY, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '', errOut = '';
    const timer = setTimeout(() => {
      try { p.kill('SIGKILL'); } catch (e) {}
      reject(Object.assign(new Error(`worker task timeout ${timeoutMs || 120000}ms`), { taskCode: 'E_TIMEOUT' }));
    }, timeoutMs || 120000);
    p.stdout.on('data', (c) => (out += c));
    p.stderr.on('data', (c) => (errOut += c));
    p.on('error', (e) => { clearTimeout(timer); reject(Object.assign(e, { taskCode: 'E_ENGINE_UNAVAILABLE' })); });
    p.on('close', () => {
      clearTimeout(timer);
      const line = out.trim().split('\n').filter(Boolean).pop();
      let j = null; try { j = JSON.parse(line); } catch (e) {}
      if (!j || typeof j.ok !== 'boolean') {
        return reject(Object.assign(new Error('worker 无结构化输出: ' + (errOut || out).trim().slice(0, 300)),
          { taskCode: 'E_WORKER_NO_OUTPUT' }));
      }
      if (!j.ok) {
        const error = j.error || {};
        return reject(Object.assign(new Error(error.message || j.error || 'worker failed'),
          { taskCode: error.code, detail: error.detail }));
      }
      resolve(Object.assign({ ok: true }, j.result || {}));   // 与 CDP 通道同形：{ok, ...}
    });
    // 提前退出的 worker 可能在写入时关掉 stdin。由 close 读取退出结果并分类。
    p.stdin.on('error', (e) => { if (e.code !== 'EPIPE') reject(e); });
    p.stdin.end(JSON.stringify({ type, params }));
  });
}

/* camoufox 的健康：模块 + Python 版本一起查。只查 import 会假绿——3.14+/3.15 能 import，真跑任务会崩 */
const CAMOUFOX_PROBE = 'import sys, json, importlib.metadata as m; print(json.dumps({"py": "%d.%d.%d" % sys.version_info[:3], "camoufox": m.version("camoufox")}))';
async function probeWorkerCap() {
  const t0 = Date.now();
  try {
    const { stdout } = await exec(CAMOUFOX_PY, ['-c', CAMOUFOX_PROBE], { timeout: 15000, maxBuffer: 65536 });
    const line = String(stdout).trim().split('\n').filter(Boolean).pop();
    const info = JSON.parse(line);
    const py = String(info.py || '');
    const base = { ms: Date.now() - t0, python: CAMOUFOX_PY, py, version: String(info.camoufox || '').slice(0, 40) };
    if (py.split('.').slice(0, 2).join('.') !== '3.13') {
      return Object.assign({ ok: false, check: 'camoufox 需 Python 3.13',
        error: `解释器是 Python ${py}：camoufox 只在 3.13 上能生成指纹，3.14+ 会 TargetClosedError` }, base);
    }
    return Object.assign({ ok: true, check: 'import camoufox + Python 3.13' }, base);
  } catch (e) {
    return { ok: false, ms: Date.now() - t0, check: 'import camoufox + Python 3.13', python: CAMOUFOX_PY,
      error: String((e && (e.stderr || e.message)) || e).slice(0, 200) };
  }
}

async function probeEngine(engine) {
  const account = `probe:health:${engine}`;
  const t0 = Date.now();
  let created = false;
  try {
    await control('DELETE', `/instances/${encodeURIComponent(account)}`).catch(() => {});   // 清掉上次探针残留
    const r = await control('POST', '/instances', { account, engine, tz: 'UTC', lang: 'en-US', headless: true });
    if (r.status >= 400) return { ok: false, error: (r.data && r.data.error) || `create failed ${r.status}`, ms: Date.now() - t0 };
    created = true;
    const cdp = r.data && r.data.instance && r.data.instance.cdp;
    if (!cdp) return { ok: false, error: 'no cdp endpoint', ms: Date.now() - t0 };
    const { stdout } = await exec(process.execPath, [DRIVER, '--cdp', cdp, 'goto', '--url', 'about:blank'], { timeout: 15000, maxBuffer: 1024 * 1024 });
    let out = null; try { out = JSON.parse(stdout); } catch (e) { out = { raw: String(stdout).slice(0, 200) }; }
    if (!out || out.ok !== true) return { ok: false, error: (out && (out.error || ('readyState=' + out.readyState))) || 'goto failed', ms: Date.now() - t0 };
    return { ok: true, ms: Date.now() - t0, cdp };
  } catch (e) {
    return { ok: false, error: String(e.stderr || e.message).slice(0, 300), ms: Date.now() - t0 };
  } finally {
    if (created) await control('DELETE', `/instances/${encodeURIComponent(account)}`).catch(() => {});
  }
}

/* ---------------- 基础设施 ---------------- */
const send = (res, code, obj, extraHeaders = {}) => {
  const body = JSON.stringify(obj);
  res.writeHead(code, Object.assign({
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
  }, extraHeaders));
  res.end(body);
};
const err = (res, code, codeName, msg, extra = {}) =>
  send(res, code, Object.assign({ ok: false, code: codeName, message: msg }, extra));
const taskRejection = (res, status, code, message, extra) =>
  err(res, status, code, message, { ...extra, error: { code, message } });

/* 代理校验：Chromium 不认 URL 里的 user:pass，带凭据会悄悄直连（比报错危险）；
 * 只允许 http/https/socks5/socks5h。报错不回显 proxy 值，避免凭据进日志/响应。 */
const PROXY_SCHEMES = new Set(['http:', 'https:', 'socks5:', 'socks5h:']);
function validateProxy(raw) {
  let u;
  try {
    u = new URL(String(raw));
  } catch (e) {
    return { code: 'E_PROXY_SCHEME', message: 'proxy 不是合法 URL；只允许 http/https/socks5/socks5h' };
  }
  if (!PROXY_SCHEMES.has(u.protocol)) {
    return { code: 'E_PROXY_SCHEME', message: 'proxy scheme 不支持；只允许 http/https/socks5/socks5h' };
  }
  if (u.username || u.password) {
    return {
      code: 'E_PROXY_CREDENTIALS',
      message: '凭据不能写进 proxy URL：Chromium 不认证，会悄悄直连。请起本地桥 `node farm/proxy-bridge.js --port 18080`，并把 proxy 设为 http://127.0.0.1:18080',
    };
  }
  return null;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = '', n = 0;
    req.on('data', (c) => { n += c.length; if (n > 262144) { reject(new Error('body too large')); req.destroy(); } b += c; });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { reject(new Error('bad json')); } });
    req.on('error', reject);
  });
}

async function control(method, p, body, base = CONTROL) {
  const r = await fetch(base + p, {
    method,
    headers: Object.assign({ 'content-type': 'application/json' },
      CTRL_TOKEN ? { 'x-farm-token': CTRL_TOKEN } : {}),
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let data; try { data = text ? JSON.parse(text) : {}; } catch (e) { data = { raw: text }; }
  return { status: r.status, data };
}

/* 幂等：key → {at, status, body}（24h） */
const idem = new Map();
const IDEM_TTL = 24 * 3600 * 1000;
function idemGet(k) {
  const v = idem.get(k);
  if (!v) return null;
  if (Date.now() - v.at > IDEM_TTL) { idem.delete(k); return null; }
  return v;
}

/* 限流：租户 token bucket */
const buckets = new Map();
function allow(tenant) {
  const now = Date.now();
  const b = buckets.get(tenant) || { tokens: RPS, ts: now };
  b.tokens = Math.min(RPS, b.tokens + ((now - b.ts) / 1000) * RPS);
  b.ts = now;
  if (b.tokens < 1) { buckets.set(tenant, b); return false; }
  b.tokens -= 1; buckets.set(tenant, b); return true;
}

/* 任务表：task_id → {status, result, error, at}（10 分钟 TTL，与契约一致） */
const tasks = new Map();
const TASK_TTL = 10 * 60 * 1000;
function parseTaskError(text) {
  try {
    const error = JSON.parse(text);
    if (error && typeof error.code === 'string' && typeof error.message === 'string') return error;
  } catch (e) {}
  return null;
}

function failTask(taskId, e, fallbackCode = 'E_INTERNAL') {
  const message = String(e.stderr || '').trim() || String(e.stdout || '').trim() || String(e.message || e);
  const error = parseTaskError(message);
  const detail = error?.detail ?? e.detail;
  tasks.set(taskId, {
    status: 'failed',
    error: {
      code: e.taskCode || error?.code || fallbackCode,
      message: (error?.message || message).slice(0, 800),
      ...(detail === undefined ? {} : { detail }),
    },
    at: Date.now(),
  });
}

setInterval(() => {
  const now = Date.now();
  for (const [k, v] of tasks) if (now - v.at > TASK_TTL) tasks.delete(k);
}, 60 * 1000).unref();

/* ---------------- 路由 ---------------- */
const server = http.createServer(async (req, res) => {
  const rid = crypto.randomUUID();
  res.setHeader('x-request-id', rid);
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/v1/health') {
      const hosts = [];
      let allUp = true;
      for (const base of CONTROLS) {
        const c = await control('GET', '/health', null, base).catch((e) => ({ status: 502, data: { error: e.message } }));
        if (c.status !== 200) allUp = false;
        hosts.push({ control: base, control_status: c.status === 200 ? 'up' : 'down', running: (c.data && c.data.running) || 0 });
      }
      const engines = {};
      for (const [k, v] of Object.entries(ENGINE_CAPS)) engines[k] = v.transport === 'worker' ? 'unverified' : (allUp ? 'up' : 'down');
      const probe = url.searchParams.get('probe');
      if (probe !== '1' && probe !== 'true') {
        return send(res, 200, { ok: allUp, gateway: 'up', control: allUp ? 'up' : 'down', version: VERSION, contract_version: CONTRACT_VERSION, hosts, engines });
      }
      /* probe=1 会真起浏览器：只对该分支校验 Bearer（health 本身仍免鉴权） */
      if (TOKEN) {
        const got = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
        if (got !== TOKEN) return err(res, 401, 'E_UNAUTH', 'invalid token');
      }
      // 真探针：实际起临时实例跑一次 goto about:blank；linux150 需外部容器，标 unverified
      const probes = {};
      let probesOk = true;
      const at = new Date().toISOString();
      if (allUp) {
        for (const eng of PROBE_ENGINES) {
          const pr = await probeEngine(eng);
          probes[eng] = pr;
          if (!pr.ok) probesOk = false;
          engines[eng] = pr.ok ? 'up' : 'down';
        }
        const wp = await probeWorkerCap();
        probes.camoufox = wp;
        if (!wp.ok) probesOk = false;
        engines.camoufox = wp.ok ? 'up' : 'down';
      } else {
        for (const eng of PROBE_ENGINES) engines[eng] = 'down';
        engines.camoufox = 'down';
        probes.camoufox = { ok: false, error: 'control down' };
      }
      for (const k of Object.keys(engines)) {
        if (PROBE_ENGINES.includes(k) || k === 'camoufox') continue;
        engines[k] = 'unverified';
      }
      return send(res, 200, { ok: allUp && probesOk, gateway: 'up', control: allUp ? 'up' : 'down', version: VERSION, contract_version: CONTRACT_VERSION, hosts, engines,
        probe: allUp ? { at, engines: probes } : { at, skipped: 'control down' } });
    }

    /* 鉴权（/v1/health 之外） */
    if (TOKEN) {
      const got = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
      if (got !== TOKEN) return err(res, 401, 'E_UNAUTH', 'invalid token');
    }
    const tenant = String(req.headers['x-tenant-id'] || 'default');
    if (!allow(tenant)) return err(res, 429, 'E_RATE_LIMITED', 'tenant rate limited', { retry_after_s: 1 });

    /* 版本契约：平台子模式包装之前用这个校验「农场版本够不够」 */
    if (req.method === 'GET' && url.pathname === '/v1/version') {
      const want = url.searchParams.get('require');
      const c = contract();
      if (!want) return send(res, 200, Object.assign({ ok: true }, c));
      const { check } = require('../contract');
      const v = check(want);
      return send(res, v.ok ? 200 : 409, Object.assign({ ok: v.ok }, c, { require: want, satisfied: !!v.ok },
        v.ok ? {} : { code: 'E_VERSION_REQUIRED', message: `farm ${VERSION} < required ${want}` }));
    }

    /* 1) 创建会话 */
    if (req.method === 'POST' && url.pathname === '/v1/sessions') {
      const key = req.headers['idempotency-key'];
      if (!key) return err(res, 400, 'E_BAD_REQUEST', 'Idempotency-Key required');
      const hit = idemGet(key);
      if (hit) return send(res, hit.status, hit.body);
      const b = await readBody(req);
      if (!b.account) return err(res, 400, 'E_BAD_REQUEST', 'account required');
      if (!ENGINE_CAPS[b.engine || 'chromium']) return err(res, 400, 'E_BAD_REQUEST', 'unknown engine');
      if (ATTACH_ONLY.has(b.engine || 'chromium') && !b.cdp) {
        return err(res, 422, 'E_ENGINE_REQUIRES_ATTACH',
          `engine ${b.engine || 'chromium'} cannot be provisioned by gateway; start the container and attach`,
          { engine: b.engine || 'chromium', required: 'cdp',
            hint: 'docker run 起容器后 node farm.js attach --account <acct> --cdp http://127.0.0.1:9334 --engine linux150；或 POST /v1/sessions 带 cdp 直接走 attach' });
      }

      /* 代理先校验：带凭据的 URL 会让 Chromium 悄悄直连，必须挡在调 control 之前 */
      const proxyErr = b.proxy ? validateProxy(b.proxy) : null;
      if (proxyErr) return err(res, 400, proxyErr.code, proxyErr.message);

      const sid = `${tenant}:${b.account}`;
      const list = await control('GET', '/instances').catch(() => ({ data: {} }));
      const running = (list.data.instances || []).filter((x) => String(x.account).startsWith(tenant + ':') && x.alive);
      if (running.length >= QUOTA) return err(res, 429, 'E_QUOTA_EXCEEDED', 'tenant quota exceeded', { quota: QUOTA });
      if ((list.data.instances || []).some((x) => x.account === sid && x.alive)) {
        return err(res, 409, 'E_ACCOUNT_BUSY', 'account already has a live session', { session_id: sid });
      }

      let resp;
      if (b.cdp) {
        resp = await control('POST', '/instances/attach', {
          account: sid, cdp: b.cdp, engine: b.engine || 'external',
          tz: b.tz || 'Asia/Shanghai', lang: b.lang || 'zh-CN', seed: b.fp_seed,
          platform: b.platform || null,
        });
      } else {
        resp = await control('POST', '/instances', {
          account: sid, engine: b.engine || 'chromium', tz: b.tz || 'Asia/Shanghai', lang: b.lang || 'zh-CN',
          fp_seed: b.fp_seed, proxy: b.proxy, headless: b.headless !== false, extra: b.extra,
          platform: b.platform || null,
        });
      }
      if (resp.status >= 400) {
        const code = resp.status === 409 ? 'E_ACCOUNT_BUSY' : 'E_ENGINE_UNAVAILABLE';
        const body = { ok: false, code, message: (resp.data && resp.data.error) || 'engine start failed' };
        idem.set(key, { at: Date.now(), status: 502, body });
        return send(res, 502, body);
      }

      let check = null;
      if (b.require_check !== false) {
        const ck = await control('POST', `/instances/${encodeURIComponent(sid)}/check`).catch(() => null);
        check = ck && ck.data && ck.data.check ? { ok: !!ck.data.ok, fails: ck.data.check.fails || [], canvas: (ck.data.check.probe || {}).canvas && ck.data.check.probe.canvas.hash } : null;
      }
      const body = {
        session_id: sid, engine: b.engine || 'chromium', platform: b.platform || null,
        cdp: resp.data && resp.data.instance ? resp.data.instance.cdp : (b.cdp || null),
        tz: b.tz, lang: b.lang, fp_seed: b.fp_seed || null, status: 'running',
        check, created_at: new Date().toISOString(),
      };
      idem.set(key, { at: Date.now(), status: 201, body });
      return send(res, 201, body);
    }

    /* 2) 列表 */
    if (req.method === 'GET' && url.pathname === '/v1/sessions') {
      const pf = url.searchParams.get('platform');
      const c = await control('GET', '/instances');
      const items = (c.data.instances || [])
        .filter((x) => String(x.account).startsWith(tenant + ':'))
        .filter((x) => !pf || x.platform === pf);
      return send(res, 200, { ok: true, platform: pf || null, sessions: items });
    }

    /* 4/5) 任务 */
    if (parts[0] === 'v1' && parts[1] === 'sessions' && parts[3] === 'tasks' && req.method === 'POST') {
      const sid = decodeURIComponent(parts[2]);
      const b = await readBody(req);
      const type = b.type;
      if (typeof type !== 'string' || !Object.hasOwn(TASK_REGISTRY, type)) {
        return taskRejection(res, 422, 'E_UNSUPPORTED_TASK', 'unknown task type', { type });
      }
      const s = await control('GET', `/instances/${encodeURIComponent(sid)}`);
      if (s.status === 404) return err(res, 404, 'E_SESSION_NOT_FOUND', 'session not found');
      const eng = s.data.instance.engine || 'chromium';
      const caps = ENGINE_CAPS[eng];
      if (!caps) return taskRejection(res, 422, 'E_UNSUPPORTED_TASK', `unknown engine ${eng}`, { engine: eng });
      /* worker 传输（camoufox）：没有 CDP，把同样的任务交给 camoufox_worker.py，返回形状对齐 CDP 通道 */
      if (caps.transport === 'worker') {
        if (!caps.tasks.includes(type)) {
          return taskRejection(res, 422, 'E_UNSUPPORTED_TASK', `engine ${eng} does not support task ${type}`, { engine: eng, type, supported: caps.tasks });
        }
        const taskId = b.task_id || crypto.randomUUID();
        if (tasks.has(taskId)) return send(res, 202, { task_id: taskId, status: tasks.get(taskId).status });
        tasks.set(taskId, { status: 'running', at: Date.now() });
        runWorkerTask(s.data.instance, type, b.params || {}, b.timeout_ms)
          .then((out) => tasks.set(taskId, { status: 'succeeded', result: out, at: Date.now() }))
          .catch((e) => failTask(taskId, e));
        return send(res, 202, { task_id: taskId, status: 'queued', transport: 'worker' });
      }
      if (caps.transport !== 'cdp') {
        return taskRejection(res, 422, 'E_UNSUPPORTED_TASK', `engine ${eng} has no task channel`, { engine: eng });
      }
      const cdp = s.data.instance.cdp;
      if (!cdp) return taskRejection(res, 502, 'E_CDP_UNREACHABLE', 'session has no cdp endpoint');
      const taskId = b.task_id || crypto.randomUUID();
      if (tasks.has(taskId)) return send(res, 202, { task_id: taskId, status: tasks.get(taskId).status });

      const args = [DRIVER, '--cdp', cdp].concat(TASK_REGISTRY[type](b.params || {}));
      tasks.set(taskId, { status: 'running', at: Date.now() });
      const timeout = b.timeout_ms || 30000;
      exec('node', args, { timeout, maxBuffer: 8 * 1024 * 1024 })
        .then(({ stdout }) => {
          let out; try { out = JSON.parse(stdout); } catch (e) { out = { raw: stdout.slice(0, 2000) }; }
          tasks.set(taskId, { status: 'succeeded', result: out, at: Date.now() });
        })
        .catch((e) => {
          if (e.killed && e.signal === 'SIGTERM') {
            return failTask(taskId, new Error(`driver task timeout ${timeout}ms`), 'E_TIMEOUT');
          }
          const fallback = e.code === 1 && (type === 'wait' || type === 'extract') ? 'E_TIMEOUT' : 'E_INTERNAL';
          failTask(taskId, e, fallback);
        });
      return send(res, 202, { task_id: taskId, status: 'queued' });
    }
    if (parts[0] === 'v1' && parts[1] === 'tasks' && req.method === 'GET') {
      const t = tasks.get(decodeURIComponent(parts[2]));
      if (!t) return err(res, 404, 'E_SESSION_NOT_FOUND', 'task not found');
      return send(res, 200, { ok: t.status !== 'failed', task_id: parts[2], status: t.status, result: t.result, error: t.error });
    }

    /* 6) 销毁 */
    if (req.method === 'DELETE' && parts[0] === 'v1' && parts[1] === 'sessions' && parts.length === 3) {
      const key = req.headers['idempotency-key'];
      if (!key) return err(res, 400, 'E_BAD_REQUEST', 'Idempotency-Key required');
      const hit = idemGet('del:' + key);
      if (hit) return send(res, hit.status, hit.body);
      const sid = decodeURIComponent(parts[2]);
      const c = await control('DELETE', `/instances/${encodeURIComponent(sid)}`);
      const body = c.status === 200
        ? { ok: true, session_id: sid, status: 'stopped', data_retained: true }
        : { ok: false, code: 'E_SESSION_NOT_FOUND', message: (c.data && c.data.error) || 'not found' };
      idem.set('del:' + key, { at: Date.now(), status: c.status === 200 ? 200 : 404, body });
      return send(res, c.status === 200 ? 200 : 404, body);
    }

    /* 3) 详情 */
    if (req.method === 'GET' && parts[0] === 'v1' && parts[1] === 'sessions' && parts.length === 3) {
      const sid = decodeURIComponent(parts[2]);
      const c = await control('GET', `/instances/${encodeURIComponent(sid)}`);
      if (c.status === 404) return err(res, 404, 'E_SESSION_NOT_FOUND', 'session not found');
      const i = c.data.instance || {};
      return send(res, 200, {
        session_id: sid, engine: i.engine, cdp: i.cdp || null, status: i.status, alive: !!i.alive,
        last_check: i.last_check_at ? { at: i.last_check_at, ok: i.last_check_ok === 1 } : null,
        history_url: `/v1/sessions/${encodeURIComponent(sid)}/checks?limit=20`,
      });
    }

    /* 8) 指纹校验 */
    if (req.method === 'POST' && url.pathname === '/v1/fingerprint/verify') {
      const b = await readBody(req);
      if (!b.session_id) return err(res, 400, 'E_BAD_REQUEST', 'session_id required');
      const q = b.with_ip ? '?ip=1' : '';
      const c = await control('POST', `/instances/${encodeURIComponent(b.session_id)}/check${q}`);
      const chk = (c.data && c.data.check) || {};
      if (c.data && c.data.ok) {
        return send(res, 200, { ok: true, fails: [], warn: chk.probe && chk.probe.ip === 'skipped' ? ['ip skipped'] : [],
          snapshot: { canvas: chk.probe && chk.probe.canvas && chk.probe.canvas.hash, webgl: chk.probe && chk.probe.webgl && chk.probe.webgl.renderer, ua: chk.probe && chk.probe.ua } });
      }
      return err(res, 424, 'E_FINGERPRINT_MISMATCH', 'fingerprint check failed', { fails: (chk && chk.fails) || [] });
    }

    /* 9) 去重（跨账号，CLI） */
    if (req.method === 'GET' && url.pathname === '/v1/fingerprint/duplicates') {
      try {
        // 单宿主：直接复用 farm.js dup（真实能力）；多宿主：按同一算法聚合
        if (CONTROLS.length === 1) {
          const { stdout } = await exec('node', [FARM, 'dup'], { timeout: 20000 });
          const d = JSON.parse(stdout);
          return send(res, d.collisions && d.collisions.length ? 409 : 200, {
            distinct_canvas: d.distinct_canvas, collisions: d.collisions || [], ok: !(d.collisions || []).length,
            hosts: CONTROLS, checked_accounts: null,
            ...(d.collisions && d.collisions.length ? { code: 'E_CANVAS_COLLISION' } : {}),
          });
        }
        const rows = [];
        for (const base of CONTROLS) {
          const list = await control('GET', '/instances', null, base).catch(() => ({ data: {} }));
          for (const inst of (list.data.instances || [])) {
            const h = await control('GET', `/instances/${encodeURIComponent(inst.account)}/history?limit=1`, null, base).catch(() => ({ data: {} }));
            const last = (h.data.history || [])[0];
            if (last && last.canvas) rows.push({ account: inst.account, canvas: last.canvas, engine: inst.engine, host: base });
          }
        }
        const by = new Map();
        for (const r of rows) by.set(r.canvas, (by.get(r.canvas) || []).concat(r.account));
        const collisions = [...by.entries()].filter(([, a]) => a.length > 1)
          .map(([canvas, accts]) => ({ canvas, n: accts.length, accts: accts.join(',') }));
        return send(res, collisions.length ? 409 : 200, {
          distinct_canvas: by.size, collisions, ok: collisions.length === 0,
          hosts: CONTROLS, checked_accounts: rows.length,
          ...(collisions.length ? { code: 'E_CANVAS_COLLISION' } : {}),
        });
      } catch (e) {
        return err(res, 500, 'E_INTERNAL', String(e.message).slice(0, 300));
      }
    }

    return err(res, 404, 'E_BAD_REQUEST', 'no route', { path: url.pathname, method: req.method });
  } catch (e) {
    return err(res, 500, 'E_INTERNAL', e.message);
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(JSON.stringify({ ok: true, service: 'dsbot-gateway', url: `http://127.0.0.1:${PORT}`,
    control: CONTROL, auth: TOKEN ? 'token' : 'none', quota: QUOTA, rps: RPS }));
});
