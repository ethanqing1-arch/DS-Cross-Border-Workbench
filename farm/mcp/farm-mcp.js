#!/usr/bin/env node
/* ============================================================================
 * farm/mcp/farm-mcp.js — dsbot-gateway 的 MCP stdio 适配器（零依赖）
 *
 * 存在意义：gateway/server.js 只有 /v1/* REST 路由，没有 MCP 握手层，直接把它
 * 注册成 streamable-http MCP 会在 initialize 就失败。这个进程用 stdio 说 MCP
 * （逐行 JSON-RPC 2.0，无 Content-Length 框），把 7 个工具转成 REST 调用。
 *
 * 用法（由 MCP 客户端拉起，不手跑）：
 *   GATEWAY_TOKEN=xxx node farm/mcp/farm-mcp.js
 *
 * 环境变量：
 *   GATEWAY_URL    默认 http://127.0.0.1:19671
 *   GATEWAY_TOKEN  /v1/* 的 Bearer 令牌；缺失时鉴权工具回 HTTP 401（不崩进程）
 *                  （本机自测可用 DSH_SECRET_GATEWAY_TOKEN 兜底，注册后由 MCP
 *                   客户端注入 GATEWAY_TOKEN，二者都不打印）
 *   FARM_MCP_DEBUG=1  只把诊断写到 stderr，stdout 永远只走协议
 *
 * 契约来源：../contract.js（ENGINE_CAPS / TASK_TYPES / VERSION），不重复定义。
 * ========================================================================== */
'use strict';

const readline = require('readline');
const crypto = require('crypto');

/* ---- 契约（读不到也能跑，只是枚举退化成字面量） ---- */
let CONTRACT = null;
try { CONTRACT = require('../contract'); } catch (e) { CONTRACT = null; }
const ENGINE_NAMES = CONTRACT ? Object.keys(CONTRACT.ENGINE_CAPS) : ['chromium', 'linux150', 'chrome', 'camoufox'];
const TASK_NAMES = CONTRACT ? CONTRACT.TASK_TYPES.slice() : ['goto', 'eval', 'click', 'type', 'shot', 'scan', 'extract', 'wait'];
const FARM_VERSION = CONTRACT ? CONTRACT.VERSION : '0.0.0';

const GATEWAY_URL = String(process.env.GATEWAY_URL || 'http://127.0.0.1:19671').replace(/\/+$/, '');
const TOKEN = String(process.env.GATEWAY_TOKEN || process.env.DSH_SECRET_GATEWAY_TOKEN || '');
const SERVER_NAME = 'farm-gateway';
const SERVER_VERSION = '0.1.0';
const SUPPORTED_PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];

const log = (s) => { if (process.env.FARM_MCP_DEBUG === '1') process.stderr.write('[farm-mcp] ' + s + '\n'); };

/* ---- 工具表 ---- */
const TOOLS = [
  {
    name: 'farm_health',
    description: '农场健康：GET /v1/health（health 本身免鉴权）。不带参数只报 control 面通断；probe=true 会真起临时实例跑一次 goto，慢但真实（linux150 标 unverified，camoufox 标 degraded/up 由探针决定）。注意 ?probe=1 分支要 Bearer：网关配了 TOKEN 时无 token 会 401 E_UNAUTH。',
    inputSchema: {
      type: 'object',
      properties: {
        probe: { type: 'boolean', description: 'true 时走 ?probe=1 真探针，默认 false' },
      },
    },
  },
  {
    name: 'farm_version',
    description: '农场版本契约：GET /v1/version。可选 require 做满足性校验（如 "1.1.0"），不满足返回 HTTP 409 与 E_VERSION_REQUIRED。',
    inputSchema: {
      type: 'object',
      properties: {
        require: { type: 'string', description: '要求的最低农场版本，如 "1.1.0"' },
      },
    },
  },
  {
    name: 'farm_sessions',
    description: '列当前租户的会话：GET /v1/sessions。返回 control 面实例列表（含 stopped 的历史账号）。',
    inputSchema: {
      type: 'object',
      properties: {
        platform: { type: 'string', description: '按平台过滤，如 amazon' },
      },
    },
  },
  {
    name: 'farm_session_create',
    description: '建会话：POST /v1/sessions（需鉴权，自动生成 Idempotency-Key）。linux150 只能带 cdp 走 attach，否则 422 E_ENGINE_REQUIRES_ATTACH。',
    inputSchema: {
      type: 'object',
      properties: {
        account: { type: 'string', description: '账号名，网关会拼成 <tenant>:<account>' },
        engine: { type: 'string', description: '引擎名，见 contract engines', enum: ENGINE_NAMES },
        cdp: { type: 'string', description: '已存在的 CDP 端点（attach 用，如 http://127.0.0.1:9334）' },
        platform: { type: 'string', description: '平台标签，如 amazon' },
        tz: { type: 'string', description: '时区，默认 Asia/Shanghai' },
        lang: { type: 'string', description: '语言，默认 zh-CN' },
        fp_seed: { type: 'string', description: '指纹种子（可复现）' },
        proxy: { type: 'string', description: '只填本地桥地址，如 http://127.0.0.1:18080（无凭据）；带账号密码的代理写在桥的 UPSTREAM_PROXY，不要写进这里——网关会 400 E_PROXY_CREDENTIALS（Chromium 不认证会悄悄直连）' },
        headless: { type: 'boolean', description: '默认 true' },
        require_check: { type: 'boolean', description: '是否建完立刻做首检，默认 true' },
        idempotency_key: { type: 'string', description: '不传则自动生成 UUID' },
      },
      required: ['account'],
    },
  },
  {
    name: 'farm_session_delete',
    description: '销毁会话：DELETE /v1/sessions/:id（需鉴权，自动生成 Idempotency-Key）。台账保留（data_retained），浏览器进程停掉。',
    inputSchema: {
      type: 'object',
      properties: {
        session_id: { type: 'string', description: '形如 default:my-account' },
        idempotency_key: { type: 'string', description: '不传则自动生成 UUID' },
      },
      required: ['session_id'],
    },
  },
  {
    name: 'farm_task',
    description: '执行任务：POST /v1/sessions/:session_id/tasks（需鉴权）；只给 task_id 时改查 GET /v1/tasks/:task_id。任务类型与 params 透传给网关。可选 wait_ms 在进程内轮询到 succeeded/failed（不新增工具）。',
    inputSchema: {
      type: 'object',
      properties: {
        session_id: { type: 'string', description: '目标会话 id；只查结果时可省略' },
        type: { type: 'string', description: '任务类型', enum: TASK_NAMES },
        params: { type: 'object', description: '任务参数，原样透传（goto: {url}，extract: {selector_map}，wait: {selector,state} 等）' },
        task_id: { type: 'string', description: '自定义任务 id；若只给 task_id 则查询该任务结果' },
        timeout_ms: { type: 'number', description: 'driver 超时，默认 30000' },
        wait_ms: { type: 'number', description: '>0 时在进程内轮询任务结果，最长等待毫秒数' },
      },
    },
  },
  {
    name: 'farm_fingerprint_verify',
    description: '指纹校验：POST /v1/fingerprint/verify（需鉴权）。对指定会话做一次 check，失败返回 HTTP 424 E_FINGERPRINT_MISMATCH 与 fails 列表。',
    inputSchema: {
      type: 'object',
      properties: {
        session_id: { type: 'string', description: '要校验的会话 id' },
        with_ip: { type: 'boolean', description: '顺带校验出口 IP，默认 false' },
      },
      required: ['session_id'],
    },
  },
];

/* ---- REST 调用：成功/失败都回原文，失败带 HTTP 状态码 ---- */
function textResult(text, isError) {
  return { content: [{ type: 'text', text: String(text) }], isError: !!isError };
}

async function callRest(method, pathPart, opts) {
  const o = opts || {};
  const headers = {};
  if (TOKEN) headers.authorization = 'Bearer ' + TOKEN;
  if (o.body !== undefined) headers['content-type'] = 'application/json';
  if (o.idempotencyKey) headers['idempotency-key'] = o.idempotencyKey;
  const url = GATEWAY_URL + pathPart;
  let res;
  try {
    res = await fetch(url, {
      method,
      headers,
      body: o.body === undefined ? undefined : JSON.stringify(o.body),
    });
  } catch (e) {
    return textResult(`E_GATEWAY_UNREACHABLE ${method} ${url}: ${(e && e.message) || e}`, true);
  }
  let text = '';
  try { text = await res.text(); } catch (e) { text = ''; }
  if (!res.ok) return textResult(`HTTP ${res.status}\n${text}`, true);
  return textResult(text, false);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---- 任务：POST 前缀路由 + 可选轮询 ---- */
async function farmTask(args) {
  if (!args.session_id) {
    if (args.task_id) return callRest('GET', '/v1/tasks/' + encodeURIComponent(String(args.task_id)));
    return textResult('E_BAD_PARAMS session_id required（只查结果时给 task_id）', true);
  }
  if (!args.type) return textResult('E_BAD_PARAMS type required', true);
  const body = { type: String(args.type), params: args.params && typeof args.params === 'object' ? args.params : {} };
  if (args.task_id) body.task_id = String(args.task_id);
  if (args.timeout_ms) body.timeout_ms = Number(args.timeout_ms);
  const first = await callRest('POST', '/v1/sessions/' + encodeURIComponent(String(args.session_id)) + '/tasks', { body });
  const waitMs = Number(args.wait_ms || 0);
  if (!(waitMs > 0) || first.isError) return first;
  let parsed = null;
  try { parsed = JSON.parse(first.content[0].text); } catch (e) { parsed = null; }
  const taskId = parsed && parsed.task_id;
  if (!taskId) return first;
  const deadline = Date.now() + waitMs;
  let last = first;
  while (Date.now() < deadline) {
    await sleep(300);
    last = await callRest('GET', '/v1/tasks/' + encodeURIComponent(taskId));
    if (last.isError) return last;
    let st = null;
    try { st = JSON.parse(last.content[0].text); } catch (e) { st = null; }
    if (st && (st.status === 'succeeded' || st.status === 'failed')) return last;
  }
  return last;
}

/* ---- 分发 ---- */
async function dispatch(name, args) {
  const a = args && typeof args === 'object' ? args : {};
  switch (name) {
    case 'farm_health':
      return callRest('GET', '/v1/health' + (a.probe ? '?probe=1' : ''));
    case 'farm_version':
      return callRest('GET', '/v1/version' + (a.require ? '?require=' + encodeURIComponent(String(a.require)) : ''));
    case 'farm_sessions':
      return callRest('GET', '/v1/sessions' + (a.platform ? '?platform=' + encodeURIComponent(String(a.platform)) : ''));
    case 'farm_session_create': {
      if (!a.account) return textResult('E_BAD_PARAMS account required', true);
      const body = {};
      for (const k of ['account', 'engine', 'tz', 'lang', 'fp_seed', 'proxy', 'headless', 'cdp', 'platform', 'require_check', 'extra']) {
        if (a[k] !== undefined) body[k] = a[k];
      }
      return callRest('POST', '/v1/sessions', { body, idempotencyKey: a.idempotency_key || crypto.randomUUID() });
    }
    case 'farm_session_delete': {
      if (!a.session_id) return textResult('E_BAD_PARAMS session_id required', true);
      return callRest('DELETE', '/v1/sessions/' + encodeURIComponent(String(a.session_id)),
        { idempotencyKey: a.idempotency_key || crypto.randomUUID() });
    }
    case 'farm_task':
      return farmTask(a);
    case 'farm_fingerprint_verify': {
      if (!a.session_id) return textResult('E_BAD_PARAMS session_id required', true);
      return callRest('POST', '/v1/fingerprint/verify', { body: { session_id: a.session_id, with_ip: !!a.with_ip } });
    }
    default:
      return null;
  }
}

/* ---- JSON-RPC 主循环（stdio：一行一条消息） ---- */
function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }

async function handle(msg) {
  if (Array.isArray(msg)) { for (const m of msg) await handle(m); return; }
  if (!msg || typeof msg !== 'object' || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') {
    if (msg && typeof msg === 'object' && 'id' in msg) {
      send({ jsonrpc: '2.0', id: msg.id === undefined ? null : msg.id, error: { code: -32600, message: 'Invalid Request' } });
    }
    return;
  }
  const isNotification = !('id' in msg);
  const id = msg.id;
  const method = msg.method;
  const params = msg.params || {};
  log(method + (isNotification ? ' (notification)' : ''));
  try {
    if (method === 'initialize') {
      const requested = typeof params.protocolVersion === 'string' ? params.protocolVersion : '';
      const protocolVersion = SUPPORTED_PROTOCOLS.includes(requested) ? requested : SUPPORTED_PROTOCOLS[SUPPORTED_PROTOCOLS.length - 1];
      if (!isNotification) {
        send({
          jsonrpc: '2.0', id, result: {
            protocolVersion,
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
            instructions: `dsbot-gateway MCP 适配层（farm ${FARM_VERSION}）。网关地址 ${GATEWAY_URL}。farm_health 免鉴权（仅 ?probe=1 真探针分支需 Bearer）；其余工具需 GATEWAY_TOKEN。`,
          },
        });
      }
      return;
    }
    if (method === 'ping') { if (!isNotification) send({ jsonrpc: '2.0', id, result: {} }); return; }
    if (method.startsWith('notifications/')) return;
    if (method === 'tools/list') {
      if (!isNotification) send({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
      return;
    }
    if (method === 'tools/call') {
      const name = params.name;
      const tool = TOOLS.find((t) => t.name === name);
      if (!tool) {
        if (!isNotification) send({ jsonrpc: '2.0', id, error: { code: -32602, message: `unknown tool: ${name}` } });
        return;
      }
      const result = await dispatch(name, params.arguments || {});
      if (!isNotification) send({ jsonrpc: '2.0', id, result });
      return;
    }
    if (!isNotification) send({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } });
  } catch (e) {
    if (!isNotification) send({ jsonrpc: '2.0', id, error: { code: -32603, message: String((e && e.message) || e) } });
  }
}

let chain = Promise.resolve();
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
rl.on('line', (line) => {
  const t = line.trim();
  if (!t) return;
  let msg;
  try { msg = JSON.parse(t); } catch (e) {
    send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
    return;
  }
  chain = chain.then(() => handle(msg));
});
rl.on('close', () => { log('stdin closed'); process.exitCode = 0; });
