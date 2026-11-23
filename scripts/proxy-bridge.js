#!/usr/bin/env node
/* ============================================================================
 * proxy-bridge.js — 本地 HTTP 代理 → 上游 SOCKS5（带用户名/口令认证）
 * 为什么需要它：Chromium 的 --proxy-server 不支持 SOCKS5 认证；反检测浏览器普遍
 * 采用「本地无认证 HTTP 代理 → 上游认证 SOCKS5」的桥接模式。本脚本是该模式的
 * 最小可运行实现，用于复现「每环境独立出口 IP」的链路。
 *
 * 用法:
 *   node proxy-bridge.js --listen 127.0.0.1:18080 \
 *        --socks [PROXY_ENDPOINT]:1080 --user [PROXY_USER] --pass [PROXY_PASS]
 *   # 然后把该环境指向 http://127.0.0.1:18080
 *
 * 支持: HTTP/1.1 明文转发（absolute-form）与 HTTPS 的 CONNECT 隧道。
 * 不终止 TLS —— 因此下游浏览器 TLS ClientHello（JA3/JA4）原样穿过，可用于指纹对照。
 * ========================================================================== */
'use strict';
const net = require('net');
const http = require('http');

/* ---------- 参数 ---------- */
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const LISTEN = arg('listen', '127.0.0.1:18080');
const SOCKS = arg('socks', '[PROXY_ENDPOINT]:1080');
const USER = arg('user', '');
const PASS = arg('pass', '');
const [LHOST, LPORT] = [LISTEN.slice(0, LISTEN.lastIndexOf(':')), +LISTEN.slice(LISTEN.lastIndexOf(':') + 1)];
const [SHOST, SPORT] = [SOCKS.slice(0, SOCKS.lastIndexOf(':')), +SOCKS.slice(SOCKS.lastIndexOf(':') + 1)];

/* ---------- SOCKS5（RFC1928/1929）客户端握手 ---------- */
function socks5Connect(dstHost, dstPort, cb) {
  const s = net.connect(SPORT, SHOST);
  let stage = 0;
  const fail = (m) => { s.destroy(); cb(new Error(m)); };

  s.on('connect', () => {
    // 1) 问候：声明 0x00(无认证) 与 0x02(用户名/口令)
    s.write(Buffer.from(USER ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]));
  });

  let buf = Buffer.alloc(0);
  s.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    if (stage === 0) {
      if (buf.length < 2) return;
      const method = buf[1]; buf = buf.slice(2);
      if (method === 0x02) {
        const u = Buffer.from(USER), p = Buffer.from(PASS);
        s.write(Buffer.concat([Buffer.from([0x01, u.length]), u, Buffer.from([p.length]), p]));
        stage = 1; return;
      }
      if (method === 0x00) { stage = 2; sendRequest(); return; }
      return fail('SOCKS5: 无可接受认证方式 (' + method + ')');
    }
    if (stage === 1) {
      if (buf.length < 2) return;
      if (buf[1] !== 0x00) return fail('SOCKS5: 认证失败');
      buf = buf.slice(2); stage = 2; sendRequest(); return;
    }
    if (stage === 2) {
      if (buf.length < 5) return;
      const rep = buf[1];
      if (rep !== 0x00) return fail('SOCKS5: CONNECT 失败 rep=' + rep);
      const atyp = buf[3];
      const need = atyp === 0x01 ? 10 : atyp === 0x04 ? 22 : 0; // IPv4 / IPv6 固定长度
      if (need && buf.length < need) return;
      s.removeAllListeners('data');
      cb(null, s);                       // 握手完成，剩余字节由调用方 pipe
      return;
    }
  });

  function sendRequest() {
    const host = Buffer.from(dstHost);
    const req = Buffer.concat([
      Buffer.from([0x05, 0x01, 0x00, 0x03, host.length]), host,
      Buffer.from([(dstPort >> 8) & 0xff, dstPort & 0xff]),
    ]);
    s.write(req);
  }

  s.on('error', (e) => cb(e));
  s.setTimeout(15000, () => fail('SOCKS5: 超时'));
}

/* ---------- HTTP 代理 ---------- */
const server = http.createServer((req, res) => {
  // absolute-form: GET http://host/path HTTP/1.1
  let u;
  try { u = new URL(req.url); } catch (e) { res.writeHead(400); return res.end('bad request'); }
  const port = +(u.port || 80);
  socks5Connect(u.hostname, port, (err, sock) => {
    if (err) { res.writeHead(502); return res.end('upstream: ' + err.message); }
    const lines = [`${req.method} ${u.pathname}${u.search} HTTP/1.1`];
    for (const [k, v] of Object.entries(req.headers)) {
      if (k.toLowerCase() === 'proxy-connection') continue;
      lines.push(`${k}: ${v}`);
    }
    sock.write(lines.join('\r\n') + '\r\n\r\n');
    req.pipe(sock);
    sock.pipe(res);
    sock.on('error', () => res.destroy());
  });
});

server.on('connect', (req, clientSock, head) => {
  const [host, port] = req.url.split(':');
  socks5Connect(host, +port, (err, sock) => {
    if (err) { clientSock.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'); return clientSock.destroy(); }
    clientSock.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) sock.write(head);
    sock.pipe(clientSock); clientSock.pipe(sock);
    const kill = () => { sock.destroy(); clientSock.destroy(); };
    sock.on('error', kill); clientSock.on('error', kill);
  });
});

server.listen(LPORT, LHOST, () => {
  console.log(`[bridge] http://${LHOST}:${LPORT}  ->  socks5://${USER ? USER + '@' : ''}${SHOST}:${SPORT}`);
  console.log('[bridge] 将该环境代理设置为上面的 HTTP 地址；出口 IP 用 https://api.ipify.org?format=json 校验');
});
