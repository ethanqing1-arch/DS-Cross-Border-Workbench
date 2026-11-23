#!/usr/bin/env node
/* ============================================================================
 * ws-probe.js — 紫鸟 GUI WS 控制通道探测
 *
 * 用途：`ziniao start ws-control --port N` 之后，确认端口是否真的在监听、
 *      握手是否被接受、以及未知命令返回什么（用于反推协议 schema）。
 *
 * 用法：
 *   node ws-probe.js --port 19999
 *   node ws-probe.js --port 19999 --key [SID_OR_SECRET] --origin http://localhost
 *   node ws-probe.js --port 19999 --send '{"id":"1","command":"ping"}'
 *
 * 输出：HTTP 状态（若有）、WS 握手结果、服务端前 5 条消息、关闭码
 * ========================================================================== */
'use strict';
const http = require('http');
const WebSocket = require('ws');

const argv = process.argv.slice(2);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const PORT = val('port', '19999');
const KEY = val('key', '');
const ORIGIN = val('origin', '');
const SEND = val('send', JSON.stringify({ id: 'probe-1', command: 'ping', args: {} }));
const TIMEOUT = parseInt(val('timeout', '6000'), 10);

function httpGet(path) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port: PORT, path, timeout: 3000 }, (res) => {
      let b = ''; res.setEncoding('utf8');
      res.on('data', (c) => (b += c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: b.slice(0, 300) }));
    });
    req.on('timeout', () => { req.destroy(); resolve({ status: 'timeout' }); });
    req.on('error', (e) => resolve({ status: 'error', error: e.message }));
  });
}

(async () => {
  const out = { port: Number(PORT), http: await httpGet('/') , ws: null };

  const q = KEY ? ('?key=' + encodeURIComponent(KEY)) : '';
  const url = `ws://127.0.0.1:${PORT}/${q}`;
  const opts = ORIGIN ? { headers: { Origin: ORIGIN } } : {};
  const ws = new WebSocket(url, opts);
  const msgs = [];

  await new Promise((resolve) => {
    const timer = setTimeout(() => { out.ws = { result: 'timeout', messages: msgs }; try { ws.terminate(); } catch (e) {} resolve(); }, TIMEOUT);
    ws.on('open', () => {
      out.ws = { result: 'open', url };
      try { ws.send(SEND); } catch (e) {}
    });
    ws.on('message', (m) => {
      if (msgs.length < 5) msgs.push(m.toString().slice(0, 500));
    });
    ws.on('unexpected-response', (_req, res) => {
      out.ws = { result: 'http_' + res.statusCode, headers: res.headers };
      clearTimeout(timer); resolve();
    });
    ws.on('error', (e) => { out.ws = { result: 'error', error: e.message, messages: msgs }; clearTimeout(timer); resolve(); });
    ws.on('close', (code, reason) => {
      out.ws = Object.assign(out.ws || {}, { result: (out.ws && out.ws.result) || 'closed', closeCode: code, reason: String(reason || '') , messages: msgs});
      clearTimeout(timer); resolve();
    });
  });

  console.log(JSON.stringify(out, null, 2));
  process.exitCode = (out.ws && out.ws.result === 'open') ? 0 : 5;
})();
