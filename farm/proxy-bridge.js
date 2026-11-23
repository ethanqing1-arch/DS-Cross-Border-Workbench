#!/usr/bin/env node
/* =============================================================================
 * proxy-bridge.js — 本地 HTTP 代理桥（零依赖）
 *
 * 为什么需要它：Chromium 的 --proxy-server 只接受一个 URL，不认 URL 里内嵌的
 * user:pass（farm/farm.js:143 原样把代理串塞给 --proxy-server，带凭据的上游
 * 代理因此完全不生效）。本桥把「带账号密码的上游」包成「无凭据的本地代理」：
 *
 *   farm_session_create(proxy="http://127.0.0.1:18080")   ← 无凭据，进程 argv 干净
 *        → 本桥（127.0.0.1:18080）→ 注入 Proxy-Authorization → 上游代理
 *
 * 支持两种流量：
 *   - CONNECT 隧道（https 走这条）
 *   - 绝对 URI 的普通 http 请求（http 走这条）
 *
 * 用法：
 *   UPSTREAM_PROXY='http://user:pass@host:port' node proxy-bridge.js [--port 18080]
 *   node proxy-bridge.js --upstream 'http://user:pass@host:port'    # 凭据会进 ps，仅调试
 *
 * 安全口径：
 *   - 上游地址/凭据只从环境变量（或显式 --upstream）读，**永不打印**；
 *     日志只打 host:port 与 auth=yes/no。
 *   - 只监听 127.0.0.1。
 *   - 上游缺失或格式错 → 拒绝启动，退出码 2。
 *
 * 退出码：0 正常运行（收到 SIGINT/SIGTERM 退出）；1 监听失败；2 配置错误。
 * ========================================================================== */
'use strict';

const http = require('http');
const net = require('net');
const { URL } = require('url');

const DEFAULT_PORT = 18080;
const LISTEN_HOST = '127.0.0.1';

function die(msg, code) {
  process.stderr.write('[proxy-bridge] ' + msg + '\n');
  process.exit(typeof code === 'number' ? code : 2);
}

function usage() {
  return [
    '用法：UPSTREAM_PROXY="http://user:pass@host:port" node proxy-bridge.js [--port 18080]',
    '      node proxy-bridge.js --upstream "http://user:pass@host:port" [--port 18080]',
    '',
    '  --port <n>      本地监听端口，默认 18080（只监听 127.0.0.1）',
    '  --upstream <u>  上游代理；建议改用 UPSTREAM_PROXY（argv 会被 ps 看见）',
    '  -h, --help      显示本帮助',
    '',
    '退出码：0 正常；1 监听失败；2 配置错误（上游缺失/格式错）。',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    port: DEFAULT_PORT,
    upstream: process.env.UPSTREAM_PROXY || '',
    upstreamFromArgv: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') {
      const n = Number(argv[++i]);
      if (!Number.isInteger(n) || n < 1 || n > 65535) die('--port 需要 1-65535 的整数');
      out.port = n;
    } else if (a === '--upstream') {
      const v = argv[++i];
      if (v === undefined) die('--upstream 缺少值');
      out.upstream = v;
      out.upstreamFromArgv = true;
    } else if (a === '-h' || a === '--help') {
      out.help = true;
    } else {
      die('未知参数 ' + a);
    }
  }
  return out;
}

/* 只解析、不打印。返回 { host, port, auth } 或 { error } */
function parseUpstream(raw) {
  if (!raw) return { error: '缺少上游代理：设置 UPSTREAM_PROXY 或 --upstream（期望 http://[user:pass@]host:port）' };
  let u;
  try {
    u = new URL(raw);
  } catch (e) {
    return { error: '上游格式错误（期望 http://[user:pass@]host:port）' };
  }
  if (u.protocol !== 'http:') return { error: '上游协议 ' + u.protocol + ' 不支持（只支持 http:）' };
  if (!u.hostname) return { error: '上游缺少 host' };
  if ((u.pathname && u.pathname !== '/') || u.search || u.hash) return { error: '上游不应带 path/query/hash' };
  const port = Number(u.port || 80);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { error: '上游端口无效' };
  let auth = null;
  if (u.username) {
    const user = decodeURIComponent(u.username);
    const pass = decodeURIComponent(u.password || '');
    auth = 'Basic ' + Buffer.from(user + ':' + pass).toString('base64');
  }
  return { host: u.hostname, port, auth };
}

function splitHostPort(s) {
  const i = s.lastIndexOf(':');
  if (i <= 0) return null;
  const host = s.slice(0, i).replace(/^\[|\]$/g, '');
  const port = Number(s.slice(i + 1));
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { host, port };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(usage() + '\n');
    process.exit(0);
  }

  const up = parseUpstream(opts.upstream);
  if (up.error) die(up.error);

  if (opts.upstreamFromArgv && up.auth) {
    process.stderr.write('[proxy-bridge] 注意：--upstream 里的凭据会出现在 ps 里，生产请改用 UPSTREAM_PROXY\n');
  }

  const authLabel = up.auth ? 'yes' : 'no';

  function log(line) {
    process.stdout.write('[proxy-bridge] ' + line + '\n');
  }

  const server = http.createServer((req, res) => {
    let target = null;
    try {
      target = new URL(String(req.url || ''));
    } catch (e) {
      target = null;
    }
    if (!target || target.protocol !== 'http:') {
      res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('proxy-bridge: 只接受绝对 URI 的 http 请求（https 请走 CONNECT）\n');
      return;
    }
    log(req.method + ' ' + target.host);
    const headers = Object.assign({}, req.headers);
    headers.host = target.host;
    delete headers['proxy-authorization'];
    delete headers['proxy-connection'];
    if (up.auth) headers['proxy-authorization'] = up.auth;

    const upReq = http.request({
      host: up.host,
      port: up.port,
      method: req.method,
      path: req.url,
      headers,
    }, (upRes) => {
      res.writeHead(upRes.statusCode || 502, upRes.headers);
      upRes.pipe(res);
    });
    upReq.on('error', () => {
      if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('proxy-bridge: upstream error\n');
    });
    req.pipe(upReq);
  });

  server.on('connect', (req, clientSocket, head) => {
    clientSocket.on('error', () => {});
    const target = splitHostPort(String(req.url || ''));
    if (!target) {
      clientSocket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
      return;
    }
    log('CONNECT ' + target.host + ':' + target.port);

    const upSocket = net.connect({ host: up.host, port: up.port }, () => {
      const lines = [
        'CONNECT ' + target.host + ':' + target.port + ' HTTP/1.1',
        'Host: ' + target.host + ':' + target.port,
      ];
      if (up.auth) lines.push('Proxy-Authorization: ' + up.auth);
      upSocket.write(lines.join('\r\n') + '\r\n\r\n');
      if (head && head.length) upSocket.write(head);
      upSocket.pipe(clientSocket);
      clientSocket.pipe(upSocket);
    });
    upSocket.on('error', () => {
      try {
        clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n');
      } catch (e) { /* 已断开 */ }
    });
    clientSocket.on('error', () => upSocket.destroy());
    clientSocket.on('close', () => upSocket.destroy());
    upSocket.on('close', () => clientSocket.destroy());
  });

  server.on('error', (e) => die('监听失败：' + (e && e.message ? e.message : e), 1));

  server.listen(opts.port, LISTEN_HOST, () => {
    log('listen ' + LISTEN_HOST + ':' + opts.port + ' -> upstream ' + up.host + ':' + up.port + ' auth=' + authLabel);
  });

  function shutdown() {
    try { server.close(); } catch (e) { /* ignore */ }
    process.exit(0);
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main();
