#!/usr/bin/env node
/* =============================================================================
 * farm-probe.js — 取页探针：把「被拦」和「没数据」分开（零依赖）
 *
 * 走 farm/mcp/farm-mcp.js 的 stdio：initialize → 建会话 → goto → eval(取证据)
 * → extract(取字段) → 删会话。stdout 只输出一段 JSON；诊断走 stderr。
 *
 * 用法：
 *   node distribution/connectors/farm-probe.js --url <url> \
 *     [--selectors title,price] [--list <容器CSS>] [--proxy <url>]
 *     [--account e2e-smoke] [--engine chromium] [--timeout-ms 45000]
 *     [--mcp <farm-mcp.js>] [--out <path>] [--verbose]
 *
 * --out：成功时写 JSONL（一行一条 item），四态都写 <path>.meta.json
 * （含 status/exit_code/item_count/...；blocked 带 matched）。不传则行为不变。
 *
 * 契约见同目录 README.md：status = ok | blocked | empty | error；
 * ok 必须 item_count ≥ 1；items 为 0 时只能是 blocked（带证据）或 empty。
 * 退出码：0 ok / 2 blocked / 3 empty / 1 error。
 *
 * 边界：不登录、不下单、不写 farm、不写真工作区；token 只从环境变量读。
 * ========================================================================== */
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const DEFAULT_SELECTORS = {
  title: 'title',
  price: '[itemprop="price"], .s-item__price, .a-price .a-offscreen, .price',
  heading: 'h1',
};

const BLOCK_PATTERNS = [
  { name: 'sorry', re: /SORRY/i },
  { name: 'error_page', re: /Error Page/i },
  { name: 'access_denied', re: /Access Denied/i },
  { name: 'captcha', re: /captcha/i },
  { name: 'robot_or_human', re: /robot or human/i },
  { name: 'activate_and_hold', re: /activate and hold/i },
  { name: 'unusual_traffic', re: /unusual traffic/i },
  { name: 'verify_you_are_human', re: /verify you are human/i },
  { name: 'are_you_a_robot', re: /are you a robot/i },
  { name: 'px_captcha', re: /px-captcha/i },
  { name: 'just_a_moment', re: /just a moment/i },
  { name: 'cf_challenge', re: /cf-challenge/i },
  { name: 'access_denied_cloudflare', re: /access to this page has been denied/i },
];

/* URL 判据：拦截页常返回 200、标题正文也可能换皮，路径本身是硬证据 */
const BLOCK_URL_PATTERNS = [
  { name: 'url_blocked', re: /\/blocked(?:[/?#]|$)/i },
  { name: 'url_captcha', re: /\/captcha(?:[/?#]|$)/i },
  { name: 'url_sorry', re: /\/sorry(?:[/?#]|$)/i },
  { name: 'url_challenge', re: /\/challenge/i },
];

const EXIT = { ok: 0, blocked: 2, empty: 3, error: 1 };

/* ---------------------------------------------------------------- 参数 */
function parseArgs(argv) {
  const a = {
    url: '',
    selectors: '',
    list: '',
    platform: '',
    query: '',
    proxy: '',
    cacheBust: false,
    account: 'e2e-smoke',
    engine: 'chromium',
    timeoutMs: 45000,
    mcp: path.resolve(__dirname, '..', '..', 'farm', 'mcp', 'farm-mcp.js'),
    out: '',
    verbose: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) throw new Error(`参数 ${k} 缺值`);
      return argv[++i];
    };
    switch (k) {
      case '--url': a.url = next(); break;
      case '--platform': a.platform = next(); break;
      case '--query': a.query = next(); break;
      case '--selectors': a.selectors = next(); break;
      case '--list': a.list = next(); break;
      case '--proxy': a.proxy = next(); break;
      case '--cache-bust': a.cacheBust = true; break;
      case '--account': a.account = next(); break;
      case '--engine': a.engine = next(); break;
      case '--timeout-ms': a.timeoutMs = Math.max(5000, parseInt(next(), 10) || 45000); break;
      case '--mcp': a.mcp = path.resolve(next()); break;
      case '--out': a.out = path.resolve(next()); break;
      case '--verbose': a.verbose = true; break;
      case '-h': case '--help':
        process.stderr.write('用法：node farm-probe.js (--url <url> | --platform <id|预设.json> [--query <q>]) [--selectors title,price] [--list <容器CSS>] [--proxy <url>] [--cache-bust] [--account e2e-smoke] [--out <path>]\n');
        process.exit(0);
        break;
      default:
        throw new Error(`未知参数：${k}`);
    }
  }
  if (!a.url && !a.platform) throw new Error('--url 或 --platform 必填');
  if (a.url && !/^https?:\/\//i.test(a.url)) throw new Error('--url 只支持 http(s)');
  if (a.proxy && !/^(https?|socks5h?):\/\//i.test(a.proxy)) {
    throw new Error('--proxy 格式不支持（只接受 http(s):// 或 socks5://，值不打印）');
  }
  return a;
}

/* 唯一 query：绕过磁盘缓存，保证 transferSize>0（命中缓存时是 0） */
function addCacheBust(rawUrl) {
  const u = new URL(rawUrl);
  u.searchParams.set('_cb', Date.now() + '-' + Math.random().toString(36).slice(2, 8));
  return u.toString();
}

function buildSelectorMap(list) {
  const map = {};
  String(list || '').split(',').forEach((raw) => {
    const s = raw.trim();
    if (!s) return;
    const eq = s.indexOf('=');
    if (eq > 0) {
      const name = s.slice(0, eq).trim();
      const css = s.slice(eq + 1).trim();
      if (name && css) map[name] = css;
      return;
    }
    map[s] = DEFAULT_SELECTORS[s] || s;
  });
  if (!Object.keys(map).length) map.title = DEFAULT_SELECTORS.title;
  return map;
}

/* 列表模式：在容器内按字段选择器循环，一次 eval 取回多条 */
function buildListExpr(containerSelector, selectors) {
  const sels = {};
  for (const [k, v] of Object.entries(selectors)) sels[k] = v;
  return '(() => {'
    + ' const sels = ' + JSON.stringify(sels) + ';'
    + ' const nodes = Array.from(document.querySelectorAll(' + JSON.stringify(containerSelector) + '));'
    + ' const items = nodes.map((el) => { const rec = {};'
    + ' for (const k of Object.keys(sels)) { const n = el.querySelector(sels[k]);'
    + ' rec[k] = n ? (n.textContent || "").replace(/\\s+/g, " ").trim() : null; }'
    + ' return rec; });'
    + ' return { ok: true, url: location.href, container_count: nodes.length, items };'
    + '})()';
}

const log = (msg) => { if (LOG_VERBOSE) process.stderr.write('[farm-probe] ' + msg + '\n'); };
let LOG_VERBOSE = false;

/* ---------------------------------------------------------------- MCP stdio 客户端 */
function createClient(child) {
  const pending = new Map();
  let nextId = 1;
  const rl = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  rl.on('line', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch (e) { return; }
    if (msg && msg.id !== undefined && pending.has(msg.id)) {
      const p = pending.get(msg.id);
      clearTimeout(p.timer);
      pending.delete(msg.id);
      if (msg.error) p.reject(new Error('JSON-RPC error: ' + JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    }
  });
  child.on('exit', (code) => {
    for (const [id, p] of pending) {
      clearTimeout(p.timer);
      p.reject(new Error('MCP 进程退出 code=' + code));
      pending.delete(id);
    }
  });
  return {
    request(method, params, timeoutMs) {
      const id = nextId++;
      const tmo = timeoutMs || 120000;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error('请求超时 ' + method)); }, tmo);
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
    },
    notify(method, params) {
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
    },
  };
}

async function callTool(mcp, name, args) {
  const res = await mcp.request('tools/call', { name, arguments: args || {} }, 180000);
  const content = (res && res.content) || [];
  const txt = (content[0] && content[0].text) || '';
  let data = null;
  try { data = JSON.parse(txt); } catch (e) { data = null; }
  return { isError: !!(res && res.isError), text: txt, data };
}

function splitHttp(text) {
  const m = /^HTTP (\d+)\n([\s\S]*)$/.exec(text || '');
  if (!m) return null;
  let body = null;
  try { body = JSON.parse(m[2]); } catch (e) { body = null; }
  return { http: Number(m[1]), body };
}

/* ---------------------------------------------------------------- 平台预设 */
const PLATFORMS_DIR = path.join(__dirname, 'platforms');
const PRESET_REQUIRED = ['id', 'name', 'list_selector', 'fields'];

/* --platform 可以是平台 id（读 platforms/<id>.json），也可以是预设文件路径（机制验证用的 fixture） */
function loadPreset(ref) {
  const asPath = ref.includes('/') || ref.endsWith('.json');
  const file = asPath ? path.resolve(ref) : path.join(PLATFORMS_DIR, ref + '.json');
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (e) {
    throw Object.assign(new Error('找不到平台预设 ' + ref + '（查过 ' + file + '）'), {
      code: 'E_PLATFORM_NOT_FOUND',
      detail: String(e && e.message),
    });
  }
  let preset;
  try {
    preset = JSON.parse(raw);
  } catch (e) {
    throw Object.assign(new Error('平台预设不是合法 JSON：' + file), { code: 'E_PLATFORM_BAD_JSON' });
  }
  return { preset, file };
}

/* 预设 → 本次实际用的 url/list/selectors。CLI 显式参数优先；缺字段直接报错，绝不静默退回默认值。 */
function resolvePlatform(args) {
  const { preset, file } = loadPreset(args.platform);
  const missing = PRESET_REQUIRED.filter((k) => {
    if (k === 'fields') return !preset.fields || typeof preset.fields !== 'object' || !Object.keys(preset.fields).length;
    return !preset[k] || String(preset[k]).trim() === '';
  });
  if (missing.length) {
    throw Object.assign(new Error('平台预设字段不全（' + file + '）：缺 ' + missing.join(', ')), {
      code: 'E_PLATFORM_INCOMPLETE',
      detail: '必填：' + PRESET_REQUIRED.join(' / ') + '；fields 至少一个字段',
    });
  }

  let url = args.url;
  if (!url) {
    const tpl = preset.search_url_template;
    if (!tpl || !String(tpl).trim()) {
      throw Object.assign(new Error('平台预设字段不全（' + file + '）：缺 search_url_template（或显式给 --url）'), {
        code: 'E_PLATFORM_INCOMPLETE',
      });
    }
    if (String(tpl).includes('{q}')) {
      if (!args.query) {
        throw Object.assign(new Error('预设模板含 {q}，必须给 --query（或改用 --url 覆盖）'), {
          code: 'E_PLATFORM_QUERY',
        });
      }
      url = String(tpl).split('{q}').join(args.query);
    } else {
      url = String(tpl);
    }
  }

  const list = args.list || preset.list_selector;
  const fields = Object.entries(preset.fields)
    .filter(([k, v]) => k && v !== null && v !== undefined && String(v).trim() !== '')
    .map(([k, v]) => k + '=' + String(v));
  if (!fields.length) {
    throw Object.assign(new Error('平台预设 fields 全是空值（' + file + '）：至少要有一个非空字段选择器'), {
      code: 'E_PLATFORM_INCOMPLETE',
    });
  }
  const selectorsStr = args.selectors || fields.join(',');
  return {
    url,
    list,
    selectorsStr,
    platform: {
      id: preset.id,
      name: preset.name,
      query: args.query || null,
      preset: file,
      verified: preset.verified || null,
      notes: preset.notes || null,
    },
  };
}

/* ---------------------------------------------------------------- 产物（--out） */
/* JSONL 只写 ok 的 items；无论四态都写 meta，没有数据时能解释为什么没有。 */
function writeArtifacts(out, args, exitCode) {
  const jsonlPath = args.out;
  const metaPath = jsonlPath + '.meta.json';
  fs.mkdirSync(path.dirname(jsonlPath), { recursive: true });

  const base = {
    platform: out.platform ? out.platform.id : null,
    query: out.query || null,
    url: out.url || null,
  };
  const fetchedAt = new Date().toISOString();
  const rows = (out.status === 'ok' ? (out.items || []) : []).map((item) =>
    Object.assign({}, base, { fetched_at: fetchedAt, status: 'ok' }, item)
  );
  fs.writeFileSync(jsonlPath, rows.length ? rows.map((r) => JSON.stringify(r)).join('\n') + '\n' : '');

  const meta = {
    platform: base.platform,
    query: base.query,
    url: base.url,
    final_url: out.final_url || null,
    status: out.status,
    exit_code: exitCode,
    item_count: out.item_count || 0,
    container_count: out.container_count === undefined ? null : out.container_count,
    transfer_size: out.nav ? out.nav.transfer_size : null,
    cache_hit: out.nav ? out.nav.cache_hit : null,
    engine: args.engine || null,
    account: out.account || null,
    preset: out.platform ? { id: out.platform.id, verified: out.platform.verified || null } : null,
  };
  if (out.status === 'blocked') meta.matched = (out.evidence && out.evidence.matched) || [];
  if (out.error) meta.error = { code: out.error.code || null, message: out.error.message || null };
  fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2) + '\n');
}

/* ---------------------------------------------------------------- 主流程 */
(async () => {
  const out = {
    status: 'error',
    url: '',
    final_url: null,
    checked_at: new Date().toISOString(),
    account: 'e2e-smoke',
    session_id: null,
    selectors: {},
    list: null,
    platform: null,
    proxy_set: false,
    cache_bust: false,
    nav: null,
    fields: null,
    missing: null,
    items: [],
    item_count: 0,
    container_count: null,
    evidence: null,
    error: null,
    cleanup: { deleted: false, delete_ok: null, data_retained: null },
  };

  let args = null;
  let child = null;
  let mcp = null;
  let created = false;
  let exitCode = EXIT.error;
  let redact = (s) => String(s);   // 设置了 --proxy 后替换成 [redacted]，值绝不打印

  const finish = (status, code) => {
    out.status = status;
    exitCode = code;
  };

  function writeOut() {
    process.stdout.write(JSON.stringify(out, null, 2) + '\n');
  }

  try {
    args = parseArgs(process.argv.slice(2));
    LOG_VERBOSE = args.verbose;
    let effUrl = args.url;
    let effList = args.list;
    let effSelectors = args.selectors;
    if (args.platform) {
      const r = resolvePlatform(args);
      effUrl = r.url;
      effList = r.list;
      effSelectors = r.selectorsStr;
      out.platform = r.platform;
      log('platform: ' + r.platform.id + ' preset=' + r.platform.preset);
    }
    out.url = effUrl;
    out.query = args.query || null;
    out.account = args.account;
    out.selectors = buildSelectorMap(effSelectors || 'title');
    out.list = effList || null;
    out.proxy_set = !!args.proxy;
    out.cache_bust = !!args.cacheBust;
    if (args.proxy) redact = (s) => String(s).split(args.proxy).join('[redacted]');
    log('proxy: ' + (args.proxy ? '已设置' : '未设置'));

    const token = process.env.GATEWAY_TOKEN || process.env.DSH_SECRET_GATEWAY_TOKEN || '';
    if (!token) {
      out.error = { code: 'E_NO_TOKEN', message: 'GATEWAY_TOKEN 未设置（可用 DSH_SECRET_GATEWAY_TOKEN）' };
      finish('error', EXIT.error);
      return;   // finally 统一输出
    }
    const gatewayUrl = String(process.env.GATEWAY_URL || 'http://127.0.0.1:19671').replace(/\/+$/, '');

    log('initialize');
    child = spawn(process.execPath, [args.mcp], {
      stdio: ['pipe', 'pipe', 'inherit'],
      env: Object.assign({}, process.env, { GATEWAY_URL: gatewayUrl, GATEWAY_TOKEN: token }),
    });
    mcp = createClient(child);

    const init = await mcp.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'dsh-farm-probe', version: '0.1.0' },
    }, 20000);
    if (!init || !init.serverInfo) throw Object.assign(new Error('initialize 失败'), { code: 'E_MCP_INIT' });
    mcp.notify('notifications/initialized', {});

    log('tools/list');
    const list = await mcp.request('tools/list', {}, 20000);
    const names = ((list && list.tools) || []).map((t) => t.name);
    for (const need of ['farm_session_create', 'farm_task', 'farm_session_delete']) {
      if (!names.includes(need)) throw Object.assign(new Error('MCP 缺工具 ' + need), { code: 'E_MCP_TOOLS' });
    }

    log('farm_session_create account=' + args.account);
    const createBody = { account: args.account, engine: args.engine, platform: 'probe', require_check: false };
    if (args.proxy) createBody.proxy = args.proxy;
    let create = await callTool(mcp, 'farm_session_create', createBody);
    if (create.isError) {
      const parsed = splitHttp(create.text);
      /* 同账号有 alive 会话（并发跑）时：先删再重试一次 */
      if (parsed && parsed.http === 409 && parsed.body && parsed.body.session_id) {
        log('E_ACCOUNT_BUSY，删掉残留会话后重试');
        await callTool(mcp, 'farm_session_delete', { session_id: parsed.body.session_id });
        create = await callTool(mcp, 'farm_session_create', createBody);
      }
    }
    if (create.isError || !create.data || !create.data.session_id) {
      out.error = { code: 'E_SESSION_CREATE', message: redact(create.text).slice(0, 800) };
      finish('error', EXIT.error);
      return;
    }
    out.session_id = create.data.session_id;
    created = true;

    const gotoUrl = args.cacheBust ? addCacheBust(out.url) : out.url;
    log('farm_task goto ' + gotoUrl);
    const goto = await callTool(mcp, 'farm_task', {
      session_id: out.session_id,
      type: 'goto',
      params: { url: gotoUrl },
      timeout_ms: args.timeoutMs,
      wait_ms: args.timeoutMs + 15000,
    });
    const g = goto.data || {};
    if (goto.isError || g.status !== 'succeeded' || !g.result || g.result.ok !== true) {
      /* 契约 3：失败的 goto 只带 error{}，没有 result/final_url。
         没成功导航就不可能是缓存命中，cache_hit 记 false（不是 null）。 */
      out.nav = { transfer_size: null, decoded_body_size: null, duration: null, response_status: null, cache_hit: false };
      const ge = g.error || {};
      out.error = {
        code: ge.code || 'E_GOTO',
        message: ge.message || 'goto 未成功',
        detail: redact(goto.text).slice(0, 800),
      };
      finish('error', EXIT.error);
      return;
    }
    out.final_url = (g.result && g.result.url) || null;

    /* 真上网校验：缓存命中时 transferSize=0。缓存页不能当 ok 返回（会把假绿传下去）。 */
    log('farm_task eval（navigation timing）');
    const navExpr = "(() => { const es = performance.getEntriesByType('navigation'); const n = es && es[0]; return { has_entry: !!n, transfer_size: n ? n.transferSize : null, decoded_body_size: n ? n.decodedBodySize : null, duration: n ? Math.round(n.duration) : null, response_status: n && n.responseStatus !== undefined ? n.responseStatus : null, cache_hit: !(n && n.transferSize > 0) }; })()";
    const navRes = await callTool(mcp, 'farm_task', {
      session_id: out.session_id,
      type: 'eval',
      params: { expr: navExpr },
      timeout_ms: args.timeoutMs,
      wait_ms: args.timeoutMs + 15000,
    });
    const navResult = (navRes.data && navRes.data.result) || null;
    const nv = (navResult && navResult.value) || navResult;   // 契约 3：eval 返回 {ok,value}；兼容旧形状
    if (navRes.isError || !navRes.data || navRes.data.status !== 'succeeded' || !nv) {
      out.error = { code: 'E_NAV_TIMING', message: 'navigation timing 取不到', detail: redact(navRes.text).slice(0, 800) };
      finish('error', EXIT.error);
      return;
    }
    out.nav = {
      transfer_size: nv.transfer_size === undefined ? null : nv.transfer_size,
      decoded_body_size: nv.decoded_body_size === undefined ? null : nv.decoded_body_size,
      duration: nv.duration === undefined ? null : nv.duration,
      response_status: nv.response_status === undefined ? null : nv.response_status,
      cache_hit: nv.cache_hit === undefined ? null : nv.cache_hit,
    };
    /* Chromium 错误页不是缓存：代理/网络不通或目标不可达时 location 会落到
       chrome-error://，transferSize 必然为 0。必须先于 E_CACHE_HIT 判掉，
       否则「出口挂了」会被教成「去查缓存」。 */
    if (typeof out.final_url === 'string' && out.final_url.startsWith('chrome-error://')) {
      out.nav.cache_hit = false;   // 错误页不是缓存命中，--out 的 meta 不许写 true
      out.error = {
        code: 'E_GOTO',
        message: '导航落到 Chromium 错误页：代理/网络不通或目标不可达，不是缓存',
        detail: 'final_url=' + out.final_url + ' transfer_size=' + out.nav.transfer_size,
      };
      finish('error', EXIT.error);
      return;
    }
    if (out.nav.cache_hit) {
      out.error = {
        code: 'E_CACHE_HIT',
        message: '页面来自缓存（transferSize=0），没有真正取数；加 --cache-bust 或换 URL 重试',
        detail: 'transfer_size=' + out.nav.transfer_size + ' decoded_body_size=' + out.nav.decoded_body_size + ' duration_ms=' + out.nav.duration,
      };
      finish('error', EXIT.error);
      return;
    }

    log('farm_task eval（取页面证据）');
    const evidenceExpr =
      '(() => ({ title: document.title || "", url: location.href, readyState: document.readyState, ' +
      'text: ((document.body && document.body.innerText) || "").replace(/\\s+/g, " ").trim().slice(0, 600) }))()';
    const ev = await callTool(mcp, 'farm_task', {
      session_id: out.session_id,
      type: 'eval',
      params: { expr: evidenceExpr },
      timeout_ms: args.timeoutMs,
      wait_ms: args.timeoutMs + 15000,
    });
    const evResult = (ev.data && ev.data.result) || null;
    const evData = (evResult && evResult.value) || evResult;   // 契约 3：eval 返回 {ok,value}；兼容旧形状
    const pageTitle = (evData && evData.title) || '';
    const pageText = (evData && evData.text) || '';
    const pageUrl = (evData && evData.url) || out.final_url || '';
    const haystack = pageTitle + '\n' + pageText;
    const matched = BLOCK_PATTERNS.filter((p) => p.re.test(haystack)).map((p) => p.name);
    let pathname = '';
    try { pathname = new URL(pageUrl).pathname; } catch (e) { pathname = ''; }
    for (const p of BLOCK_URL_PATTERNS) {
      if (p.re.test(pathname)) matched.push(p.name);
    }

    if (matched.length) {
      out.evidence = {
        page_title: pageTitle,
        page_url: pageUrl,
        ready_state: (evData && evData.readyState) || null,
        body_snippet: pageText.slice(0, 300),
        matched,
      };
      out.fields = null;
      out.missing = null;
      out.items = [];
      out.item_count = 0;
      out.container_count = null;
      finish('blocked', EXIT.blocked);
      log('blocked: ' + matched.join(','));
      return;
    }

    /* 拦截页可能换皮成普通 200 页；主文档状态码是兜底硬证据（blocked 已先判，403 墙仍归 blocked） */
    const httpStatus = out.nav && typeof out.nav.response_status === 'number' ? out.nav.response_status : null;
    if (httpStatus !== null && httpStatus >= 400) {
      out.error = {
        code: httpStatus === 404 ? 'E_NOT_FOUND' : 'E_HTTP_STATUS',
        message: httpStatus === 404
          ? '主文档 HTTP 404（页面不存在），不是可用数据页'
          : '主文档 HTTP ' + httpStatus + '（请求失败），不是可用数据页',
        detail: 'url=' + pageUrl + ' status=' + httpStatus,
      };
      finish('error', EXIT.error);
      return;
    }

    /* ---- 列表模式：容器内按字段循环，一次 eval 取回多条 ---- */
    if (out.list) {
      log('farm_task eval（列表模式 container=' + out.list + '）');
      const listRes = await callTool(mcp, 'farm_task', {
        session_id: out.session_id,
        type: 'eval',
        params: { expr: buildListExpr(out.list, out.selectors) },
        timeout_ms: args.timeoutMs,
        wait_ms: args.timeoutMs + 15000,
      });
      const listResult = (listRes.data && listRes.data.result) || null;
      const lr = (listResult && listResult.value) || listResult;   // 契约 3：eval 返回 {ok,value}；兼容旧形状
      if (listRes.isError || !listRes.data || listRes.data.status !== 'succeeded' || !lr) {
        out.error = { code: 'E_LIST', message: '列表模式 eval 未成功', detail: redact(listRes.text).slice(0, 800) };
        finish('error', EXIT.error);
        return;
      }
      const rawItems = Array.isArray(lr.items) ? lr.items : [];
      /* 容器命中数 vs 真正取到字段的条数：全空卡片剔除，避免 ok + 0 数据 */
      const kept = rawItems.filter((rec) => Object.keys(rec || {}).some((k) => {
        const v = rec[k];
        return v !== null && v !== undefined && String(v).trim() !== '';
      }));
      out.container_count = typeof lr.container_count === 'number' ? lr.container_count : rawItems.length;
      out.items = kept;
      out.item_count = kept.length;
      out.fields = null;
      out.missing = null;
      out.final_url = lr.url || out.final_url;
      out.evidence = {
        page_title: pageTitle,
        page_url: (evData && evData.url) || out.final_url,
        ready_state: (evData && evData.readyState) || null,
        body_snippet: pageText.slice(0, 300),
        matched: [],
        container_count: out.container_count,
      };
      log('列表模式：container_count=' + out.container_count + ' item_count=' + out.item_count);
      if (out.item_count >= 1) finish('ok', EXIT.ok);
      else finish('empty', EXIT.empty);
      return;
    }

    log('farm_task extract');
    const ext = await callTool(mcp, 'farm_task', {
      session_id: out.session_id,
      type: 'extract',
      params: { selector_map: out.selectors },
      timeout_ms: args.timeoutMs,
      wait_ms: args.timeoutMs + 15000,
    });
    const e = (ext.data && ext.data.result) || null;
    if (ext.isError || !ext.data || ext.data.status !== 'succeeded' || !e) {
      out.error = { code: 'E_EXTRACT', message: 'extract 未成功', detail: redact(ext.text).slice(0, 800) };
      finish('error', EXIT.error);
      return;
    }

    const fields = e.fields || {};
    const missing = e.missing || [];
    const nonEmpty = Object.keys(fields).filter((k) => {
      const v = fields[k];
      return v !== null && v !== undefined && String(v).trim() !== '';
    });
    out.fields = fields;
    out.missing = missing;
    out.items = nonEmpty.length ? [fields] : [];
    out.item_count = out.items.length;
    out.final_url = e.url || out.final_url;
    out.evidence = {
      page_title: pageTitle,
      page_url: (evData && evData.url) || out.final_url,
      ready_state: (evData && evData.readyState) || null,
      body_snippet: pageText.slice(0, 300),
      matched: [],
    };

    if (out.item_count >= 1) finish('ok', EXIT.ok);
    else finish('empty', EXIT.empty);
  } catch (err) {
    out.error = {
      code: (err && err.code) || 'E_PROBE',
      message: redact((err && err.message) || err),
      detail: err && err.detail ? redact(err.detail).slice(0, 800) : null,
    };
    finish('error', EXIT.error);
  } finally {
    if (created && mcp) {
      try {
        log('farm_session_delete');
        const del = await callTool(mcp, 'farm_session_delete', { session_id: out.session_id });
        const d = del.data || {};
        out.cleanup.delete_ok = !del.isError && d.ok === true;
        out.cleanup.deleted = out.cleanup.delete_ok;
        out.cleanup.data_retained = d.data_retained === undefined ? null : d.data_retained;
        if (!out.cleanup.delete_ok) out.cleanup.error = redact(del.text).slice(0, 400);
      } catch (e2) {
        out.cleanup.delete_ok = false;
        out.cleanup.deleted = false;
        out.cleanup.error = redact((e2 && e2.message) || e2);
      }
    }
    if (args && args.out) {
      try {
        writeArtifacts(out, args, exitCode);
      } catch (e) {
        process.stderr.write('[farm-probe] 写 --out 失败：' + redact((e && e.message) || e) + '\n');
      }
    }
    writeOut();
    if (child) { try { child.stdin.end(); } catch (e) {} }
    const hardExit = setTimeout(() => process.exit(exitCode), 2000);
    hardExit.unref();
    process.exitCode = exitCode;
  }
})();
