#!/usr/bin/env node
/* =============================================================================
 * farm-probe.js — 取页探针：把「被拦」和「没数据」分开（零依赖）
 *
 * 走 farm/mcp/farm-mcp.js 的 stdio：initialize → 建会话 → goto → eval(取证据)
 * → extract(取字段) → 删会话。stdout 只输出一段 JSON；诊断走 stderr。
 *
 * 用法：
 *   node distribution/connectors/farm-probe.js --url <url> \
 *     [--selectors title,price] [--account e2e-smoke] [--engine chromium]
 *     [--timeout-ms 45000] [--mcp <farm-mcp.js>] [--verbose]
 *
 * 契约见同目录 README.md：status = ok | blocked | empty | error；
 * ok 必须 item_count ≥ 1；items 为 0 时只能是 blocked（带证据）或 empty。
 * 退出码：0 ok / 2 blocked / 3 empty / 1 error。
 *
 * 边界：不登录、不下单、不写 farm、不写真工作区；token 只从环境变量读。
 * ========================================================================== */
'use strict';

const { spawn } = require('node:child_process');
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
];

const EXIT = { ok: 0, blocked: 2, empty: 3, error: 1 };

/* ---------------------------------------------------------------- 参数 */
function parseArgs(argv) {
  const a = {
    url: '',
    selectors: 'title',
    account: 'e2e-smoke',
    engine: 'chromium',
    timeoutMs: 45000,
    mcp: path.resolve(__dirname, '..', '..', 'farm', 'mcp', 'farm-mcp.js'),
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
      case '--selectors': a.selectors = next(); break;
      case '--account': a.account = next(); break;
      case '--engine': a.engine = next(); break;
      case '--timeout-ms': a.timeoutMs = Math.max(5000, parseInt(next(), 10) || 45000); break;
      case '--mcp': a.mcp = path.resolve(next()); break;
      case '--verbose': a.verbose = true; break;
      case '-h': case '--help':
        process.stderr.write('用法：node farm-probe.js --url <url> [--selectors title,price] [--account e2e-smoke]\n');
        process.exit(0);
        break;
      default:
        throw new Error(`未知参数：${k}`);
    }
  }
  if (!a.url) throw new Error('--url 必填');
  if (!/^https?:\/\//i.test(a.url)) throw new Error('--url 只支持 http(s)');
  return a;
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
    fields: null,
    missing: null,
    items: [],
    item_count: 0,
    evidence: null,
    error: null,
    cleanup: { deleted: false, delete_ok: null, data_retained: null },
  };

  let child = null;
  let mcp = null;
  let created = false;
  let exitCode = EXIT.error;

  const finish = (status, code) => {
    out.status = status;
    exitCode = code;
  };

  function writeOut() {
    process.stdout.write(JSON.stringify(out, null, 2) + '\n');
  }

  try {
    const args = parseArgs(process.argv.slice(2));
    LOG_VERBOSE = args.verbose;
    out.url = args.url;
    out.account = args.account;
    out.selectors = buildSelectorMap(args.selectors);

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
    let create = await callTool(mcp, 'farm_session_create', {
      account: args.account, engine: args.engine, platform: 'probe', require_check: false,
    });
    if (create.isError) {
      const parsed = splitHttp(create.text);
      /* 同账号有 alive 会话（并发跑）时：先删再重试一次 */
      if (parsed && parsed.http === 409 && parsed.body && parsed.body.session_id) {
        log('E_ACCOUNT_BUSY，删掉残留会话后重试');
        await callTool(mcp, 'farm_session_delete', { session_id: parsed.body.session_id });
        create = await callTool(mcp, 'farm_session_create', {
          account: args.account, engine: args.engine, platform: 'probe', require_check: false,
        });
      }
    }
    if (create.isError || !create.data || !create.data.session_id) {
      out.error = { code: 'E_SESSION_CREATE', message: create.text.slice(0, 800) };
      finish('error', EXIT.error);
      return;
    }
    out.session_id = create.data.session_id;
    created = true;

    log('farm_task goto ' + args.url);
    const goto = await callTool(mcp, 'farm_task', {
      session_id: out.session_id,
      type: 'goto',
      params: { url: args.url },
      timeout_ms: args.timeoutMs,
      wait_ms: args.timeoutMs + 15000,
    });
    const g = goto.data || {};
    if (goto.isError || g.status !== 'succeeded' || !g.result || g.result.ok !== true) {
      out.error = { code: 'E_GOTO', message: 'goto 未成功', detail: String(goto.text || '').slice(0, 800) };
      finish('error', EXIT.error);
      return;
    }
    out.final_url = (g.result && g.result.url) || null;

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
    const evData = (ev.data && ev.data.result) || null;
    const pageTitle = (evData && evData.title) || '';
    const pageText = (evData && evData.text) || '';
    const haystack = pageTitle + '\n' + pageText;
    const matched = BLOCK_PATTERNS.filter((p) => p.re.test(haystack)).map((p) => p.name);

    if (matched.length) {
      out.evidence = {
        page_title: pageTitle,
        page_url: (evData && evData.url) || out.final_url,
        ready_state: (evData && evData.readyState) || null,
        body_snippet: pageText.slice(0, 300),
        matched,
      };
      out.fields = null;
      out.missing = null;
      out.items = [];
      out.item_count = 0;
      finish('blocked', EXIT.blocked);
      log('blocked: ' + matched.join(','));
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
      out.error = { code: 'E_EXTRACT', message: 'extract 未成功', detail: String(ext.text || '').slice(0, 800) };
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
      message: String((err && err.message) || err),
      detail: err && err.detail ? String(err.detail).slice(0, 800) : null,
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
        if (!out.cleanup.delete_ok) out.cleanup.error = String(del.text || '').slice(0, 400);
      } catch (e2) {
        out.cleanup.delete_ok = false;
        out.cleanup.deleted = false;
        out.cleanup.error = String((e2 && e2.message) || e2);
      }
    }
    writeOut();
    if (child) { try { child.stdin.end(); } catch (e) {} }
    const hardExit = setTimeout(() => process.exit(exitCode), 2000);
    hardExit.unref();
    process.exitCode = exitCode;
  }
})();
