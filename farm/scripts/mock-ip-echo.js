#!/usr/bin/env node
/* ============================================================================
 * mock-ip-echo.js — 本地出口 IP 回显服务（闭合"无外网无法验证 check 的 ip 字段"）
 *
 * 用途：把 FARM_IP_ECHO 指向本服务，check/preflight 的 ip 字段就能被断言，
 *       不依赖能否访问 api.ipify.org。
 *
 * 用法：
 *   node scripts/mock-ip-echo.js --port 19700 --ip 203.0.113.10
 *   FARM_IP_ECHO=http://127.0.0.1:19700/ip node farm.js check --account A
 * ========================================================================== */
'use strict';
const http = require('http');
const argv = process.argv.slice(2);
const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const PORT = parseInt(val('port', '19700'), 10);
const IP = val('ip', '203.0.113.10');

const server = http.createServer((req, res) => {
  const body = JSON.stringify({ ip: IP, seenFrom: req.socket.remoteAddress, path: req.url });
  res.writeHead(200, {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': '*',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
});
server.listen(PORT, '127.0.0.1', () => {
  console.log(JSON.stringify({ ok: true, service: 'mock-ip-echo', url: `http://127.0.0.1:${PORT}/ip`, fakeIp: IP }));
});
