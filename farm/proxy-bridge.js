#!/usr/bin/env node
/* =============================================================================
 * proxy-bridge.js — 本地代理桥（零依赖）
 *
 * 为什么需要它：Chromium 的 --proxy-server 只接受一个 URL，不认 URL 里内嵌的
 * user:pass（farm/farm.js:143 原样把代理串塞给 --proxy-server，带凭据的上游
 * 代理因此完全不生效）。本桥把「带账号密码的上游」包成「无凭据的本地代理」：
 *
 *   farm_session_create(proxy="http://127.0.0.1:18080")   ← 无凭据，进程 argv 干净
 *        → 本桥（127.0.0.1:18080）→ 上游（注入凭据）→ 目标站
 *
 * 支持的上游：
 *   http://[user:pass@]host:port        HTTP 代理：注入 Proxy-Authorization: Basic
 *   socks5://[user:pass@]host:port      SOCKS5：本地解析目标域名（IPv4）后按 IP 连
 *   socks5h://[user:pass@]host:port     SOCKS5：域名交给上游解析（远程 DNS）
 *   认证：RFC 1929 用户名密码；未配置凭据时只报 NO AUTH。
 *
 * 本地侧（给 Chromium）永远是普通 HTTP 代理：
 *   - CONNECT 隧道（https）
 *   - 绝对 URI 的普通 http 请求（http）
 *
 * 用法：
 *   UPSTREAM_PROXY='http://user:pass@host:port'   node proxy-bridge.js [--port 18080]
 *   UPSTREAM_PROXY='socks5://user:pass@host:port' node proxy-bridge.js [--port 18080]
 *   UPSTREAM_PROXY='socks5h://user:pass@host:port' node proxy-bridge.js [--port 18080]
 *   node proxy-bridge.js --upstream 'http://user:pass@host:port'    # 凭据会进 ps，仅调试
 *
 * 安全口径：
 *   - 上游地址/凭据只从环境变量（或显式 --upstream）读，**永不打印**；
 *     日志只打 scheme、host:port 与 auth=yes/no。
 *   - 只监听 127.0.0.1。
 *   - 上游缺失或格式错 → 拒绝启动，退出码 2。
 *
 * 退出码：0 正常运行（收到 SIGINT/SIGTERM 退出）；1 监听失败；2 配置错误。
 * ========================================================================== */
'use strict';

const http = require('http');
const net = require('net');
const dns = require('dns').promises;
const { URL } = require('url');

const DEFAULT_PORT = 18080;
const LISTEN_HOST = '127.0.0.1';
const HANDSHAKE_TIMEOUT_MS = 10000;

/* SOCKS5 应答码（RFC 1928） */
const SOCKS_REP = {
  1: 'general failure',
  2: 'connection not allowed by ruleset',
  3: 'network unreachable',
  4: 'host unreachable',
  5: 'connection refused',
  6: 'TTL expired',
  7: 'command not supported',
  8: 'address type not supported',
};

function die(msg, code) {
  process.stderr.write('[proxy-bridge] ' + msg + '\n');
  process.exit(typeof code === 'number' ? code : 2);
}

function usage() {
  return [
    '用法：UPSTREAM_PROXY="http://user:pass@host:port" node proxy-bridge.js [--port 18080]',
    '      UPSTREAM_PROXY="socks5://user:pass@host:port" node proxy-bridge.js [--port 18080]',
    '      UPSTREAM_PROXY="socks5h://user:pass@host:port" node proxy-bridge.js [--port 18080]',
    '',
    '  --port <n>      本地监听端口，默认 18080（只监听 127.0.0.1）',
    '  --upstream <u>  上游代理；建议改用 UPSTREAM_PROXY（argv 会被 ps 看见）',
    '  -h, --help      显示本帮助',
    '',
    '上游协议：',
    '  http://      HTTP 代理，Basic 认证（Proxy-Authorization）',
    '  socks5://    SOCKS5；目标域名本地解析成 IPv4 后按 IP 连',
    '  socks5h://   SOCKS5；目标域名交给上游解析（远程 DNS）',
    '',
    '退出码：0 正常；1 监听失败；2 配置错误（上游缺失/格式错/socks 缺端口）。',
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

function stripBrackets(host) {
  return String(host || '').replace(/^\[|\]$/g, '');
}

/* 只解析、不打印。返回 { kind, scheme, remoteDns, host, port, auth, authHeader } 或 { error } */
function parseUpstream(raw) {
  if (!raw) return { error: '缺少上游代理：设置 UPSTREAM_PROXY 或 --upstream（http:// 或 socks5[h]://[user:pass@]host:port）' };
  let u;
  try {
    u = new URL(raw);
  } catch (e) {
    return { error: '上游格式错误（期望 http://[user:pass@]host:port 或 socks5[h]://[user:pass@]host:port）' };
  }
  const proto = u.protocol;
  const isHttp = proto === 'http:';
  const isSocks = proto === 'socks5:' || proto === 'socks5h:';
  if (!isHttp && !isSocks) {
    return { error: '上游协议 ' + proto + ' 不支持（支持 http:、socks5:、socks5h:）' };
  }
  if (!u.hostname) return { error: '上游缺少 host' };
  if (isSocks && !u.port) {
    return { error: 'socks5 上游必须带端口（socks5[h]://[user:pass@]host:port）' };
  }
  const port = Number(u.port || 80);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { error: '上游端口无效' };
  if ((u.pathname && u.pathname !== '/') || u.search || u.hash) return { error: '上游不应带 path/query/hash' };
  let auth = null;
  if (u.username) {
    auth = { user: decodeURIComponent(u.username), pass: decodeURIComponent(u.password || '') };
  }
  return {
    kind: isHttp ? 'http' : 'socks5',
    scheme: proto.replace(':', ''),
    remoteDns: proto === 'socks5h:',
    host: stripBrackets(u.hostname),
    port,
    auth,
    authHeader: auth ? 'Basic ' + Buffer.from(auth.user + ':' + auth.pass).toString('base64') : null,
  };
}

function splitHostPort(s) {
  const i = s.lastIndexOf(':');
  if (i <= 0) return null;
  const host = stripBrackets(s.slice(0, i));
  const port = Number(s.slice(i + 1));
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { host, port };
}

function ipv6ToBuffer(addr) {
  const parts = String(addr).split('::');
  const head = parts[0] ? parts[0].split(':') : [];
  const tail = parts.length > 1 && parts[1] ? parts[1].split(':') : [];
  const fill = 8 - (head.length + tail.length);
  const groups = head.concat(new Array(Math.max(fill, 0)).fill('0'), tail);
  const buf = Buffer.alloc(16);
  groups.forEach((g, i) => buf.writeUInt16BE(parseInt(g, 16) || 0, i * 2));
  return buf;
}

/* 从 socket 精确读 N 字节，握手用；握手结束后 detach 把剩余字节还给 socket */
function makeReader(sock) {
  let buf = Buffer.alloc(0);
  let waiter = null;
  let failure = null;
  const flush = () => {
    if (failure) {
      const w = waiter;
      waiter = null;
      if (w) w.reject(failure);
      return;
    }
    if (waiter && buf.length >= waiter.n) {
      const out = buf.slice(0, waiter.n);
      buf = buf.slice(waiter.n);
      const w = waiter;
      waiter = null;
      w.resolve(out);
    }
  };
  const onData = (d) => { buf = Buffer.concat([buf, d]); flush(); };
  const onError = (e) => { failure = failure || e; flush(); };
  const onClose = () => { failure = failure || new Error('上游连接已关闭'); flush(); };
  sock.on('data', onData);
  sock.on('error', onError);
  sock.on('close', onClose);
  return {
    read(n) {
      return new Promise((resolve, reject) => {
        waiter = { n, resolve, reject };
        flush();
      });
    },
    detach() {
      sock.removeListener('data', onData);
      sock.removeListener('error', onError);
      sock.removeListener('close', onClose);
      if (buf.length) sock.unshift(buf);
    },
  };
}

/* 建一条经过 SOCKS5 上游的 TCP 连接，返回已就绪的 socket */
function socksConnect(up, targetHost, targetPort) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host: up.host, port: up.port });
    const reader = makeReader(sock);
    let done = false;
    const timer = setTimeout(() => {
      finish(new Error('socks 握手超时（' + up.host + ':' + up.port + '）'));
    }, HANDSHAKE_TIMEOUT_MS);
    function finish(err) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (err) {
        try { sock.destroy(); } catch (e) { /* 已断开 */ }
        reject(err);
      } else {
        reader.detach();
        resolve(sock);
      }
    }
    sock.once('connect', async () => {
      try {
        /* 1) 问候：有凭据时同时提供 NO AUTH 与 USER/PASS，由上游挑 */
        const methods = up.auth ? [0x00, 0x02] : [0x00];
        sock.write(Buffer.from([0x05, methods.length].concat(methods)));
        const sel = await reader.read(2);
        if (sel[0] !== 0x05) throw new Error('socks 版本不符（上游不是 SOCKS5？）');
        if (sel[1] === 0xff) throw new Error('socks 上游不接受任何认证方式');
        if (sel[1] === 0x02) {
          if (!up.auth) throw new Error('socks 上游要求用户名密码，但未配置凭据');
          const u = Buffer.from(up.auth.user);
          const p = Buffer.from(up.auth.pass);
          if (u.length > 255 || p.length > 255) throw new Error('socks 凭据过长（用户名/密码需 ≤255 字节）');
          sock.write(Buffer.concat([Buffer.from([0x01, u.length]), u, Buffer.from([p.length]), p]));
          const ar = await reader.read(2);
          if (ar[1] !== 0x00) throw new Error('socks 认证失败（用户名或密码错误）');
        } else if (sel[1] !== 0x00) {
          throw new Error('socks 上游选择了不支持的认证方式 0x' + sel[1].toString(16));
        }

        /* 2) CONNECT：域名 / 本地解析后的 IP / 目标本身就是 IP */
        let atyp;
        let addr;
        const ipFamily = net.isIP(targetHost);
        if (ipFamily === 4) {
          atyp = 0x01;
          addr = Buffer.from(targetHost.split('.').map(Number));
        } else if (ipFamily === 6) {
          atyp = 0x04;
          addr = ipv6ToBuffer(targetHost);
        } else if (up.remoteDns) {
          const name = Buffer.from(targetHost);
          if (name.length > 255) throw new Error('socks 域名过长（>255 字节）');
          atyp = 0x03;
          addr = Buffer.concat([Buffer.from([name.length]), name]);
        } else {
          const resolved = await dns.lookup(targetHost, { family: 4 });
          atyp = 0x01;
          addr = Buffer.from(resolved.address.split('.').map(Number));
        }
        sock.write(Buffer.concat([
          Buffer.from([0x05, 0x01, 0x00, atyp]),
          addr,
          Buffer.from([targetPort >> 8, targetPort & 0xff]),
        ]));

        /* 3) 应答：ver rep rsv atyp [addr] port */
        const head = await reader.read(4);
        if (head[0] !== 0x05) throw new Error('socks 应答版本不符');
        if (head[1] !== 0x00) throw new Error('socks CONNECT 失败：' + (SOCKS_REP[head[1]] || ('rep=' + head[1])));
        let skip;
        if (head[3] === 0x01) skip = 4;
        else if (head[3] === 0x04) skip = 16;
        else if (head[3] === 0x03) {
          const len = await reader.read(1);
          skip = len[0];
        } else {
          throw new Error('socks 应答地址类型不支持');
        }
        await reader.read(skip + 2);
        finish(null);
      } catch (e) {
        finish(e);
      }
    });
    sock.once('error', (e) => finish(e));
  });
}

/* 建一条经过 HTTP 上游的 CONNECT 隧道（应答由上游原样回给客户端，407 也照传） */
function httpUpstreamConnect(up, target) {
  return new Promise((resolve, reject) => {
    const s = net.connect({ host: up.host, port: up.port }, () => {
      const lines = [
        'CONNECT ' + target.host + ':' + target.port + ' HTTP/1.1',
        'Host: ' + target.host + ':' + target.port,
      ];
      if (up.authHeader) lines.push('Proxy-Authorization: ' + up.authHeader);
      s.write(lines.join('\r\n') + '\r\n\r\n');
      resolve(s);
    });
    s.once('error', reject);
  });
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

  function upLabel() {
    return up.scheme + ' ' + up.host + ':' + up.port + ' auth=' + authLabel;
  }

  async function handleHttp(req, res) {
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

    if (up.kind === 'socks5') {
      const host = stripBrackets(target.hostname);
      const port = Number(target.port || 80);
      let sock;
      try {
        sock = await socksConnect(up, host, port);
      } catch (e) {
        log('SOCKS 失败（' + host + ':' + port + '）：' + String((e && e.message) || e));
        res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('proxy-bridge: socks upstream error\n');
        return;
      }
      const upReq = http.request({
        host,
        port,
        method: req.method,
        path: target.pathname + target.search,
        headers,
        agent: false,
        createConnection: () => sock,
      }, (upRes) => {
        res.writeHead(upRes.statusCode || 502, upRes.headers);
        upRes.pipe(res);
      });
      upReq.on('error', (e) => {
        log('SOCKS 请求失败（' + host + ':' + port + '）：' + String((e && e.message) || e));
        if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('proxy-bridge: socks upstream error\n');
      });
      req.pipe(upReq);
      return;
    }

    if (up.authHeader) headers['proxy-authorization'] = up.authHeader;
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
  }

  async function handleConnect(req, clientSocket, head) {
    clientSocket.on('error', () => {});
    const target = splitHostPort(String(req.url || ''));
    if (!target) {
      clientSocket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
      return;
    }
    log('CONNECT ' + target.host + ':' + target.port);

    let upSocket;
    try {
      upSocket = up.kind === 'socks5'
        ? await socksConnect(up, target.host, target.port)
        : await httpUpstreamConnect(up, target);
      /* SOCKS 上游没有 HTTP 应答；对本地客户端来说我们是代理，得自己回 200 */
      if (up.kind === 'socks5') clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    } catch (e) {
      log('上游连接失败（' + target.host + ':' + target.port + '）：' + String((e && e.message) || e));
      try { clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (e2) { /* 已断开 */ }
      return;
    }

    upSocket.on('error', () => {
      try { clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (e) { /* 已断开 */ }
    });
    clientSocket.on('error', () => upSocket.destroy());
    clientSocket.on('close', () => upSocket.destroy());
    upSocket.on('close', () => clientSocket.destroy());
    if (head && head.length) upSocket.write(head);
    upSocket.pipe(clientSocket);
    clientSocket.pipe(upSocket);
  }

  const server = http.createServer((req, res) => {
    handleHttp(req, res).catch((e) => {
      log('请求处理失败：' + String((e && e.message) || e));
      try {
        if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('proxy-bridge: error\n');
      } catch (e2) { /* 已断开 */ }
    });
  });

  server.on('connect', (req, clientSocket, head) => {
    handleConnect(req, clientSocket, head).catch((e) => {
      log('CONNECT 处理失败：' + String((e && e.message) || e));
      try { clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (e2) { /* 已断开 */ }
    });
  });

  server.on('error', (e) => die('监听失败：' + (e && e.message ? e.message : e), 1));

  server.listen(opts.port, LISTEN_HOST, () => {
    log('listen ' + LISTEN_HOST + ':' + opts.port + ' -> upstream ' + upLabel());
  });

  function shutdown() {
    try { server.close(); } catch (e) { /* ignore */ }
    process.exit(0);
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main();
