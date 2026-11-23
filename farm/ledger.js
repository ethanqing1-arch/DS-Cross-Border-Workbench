#!/usr/bin/env node
/* ============================================================================
 * ledger.js — 账号台账（SQLite，node:sqlite 内置模块，无第三方依赖）
 *
 * 表：accounts（账号 → 端口/代理/时区/语言/pid/状态）
 *     checks（每次体检一行，保留历史，可回溯"哪天开始不对劲"）
 *
 * 用法：
 *   node ledger.js stats
 *   node ledger.js list
 *   node ledger.js history --account acc01 [--limit 20]
 *   node ledger.js dump            # 全量 JSON，便于导出给 DS-Bot
 * ========================================================================== */
'use strict';
const path = require('path');
const fs = require('fs');
const { DatabaseSync } = require('node:sqlite');

const DB_PATH = process.env.FARM_DB || path.join(__dirname, 'farm.db');
const db = new DatabaseSync(DB_PATH);

db.exec(`
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 3000;
CREATE TABLE IF NOT EXISTS accounts (
  account       TEXT PRIMARY KEY,
  store_id      TEXT,
  platform      TEXT,
  port          INTEGER,
  proxy         TEXT,
  tz            TEXT,
  lang          TEXT,
  extra         TEXT,
  profile       TEXT,
  headless      INTEGER,
  pid           INTEGER,
  status        TEXT,
  created_at    TEXT,
  updated_at    TEXT,
  last_check_at TEXT,
  last_check_ok INTEGER
);
CREATE TABLE IF NOT EXISTS checks (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  account  TEXT NOT NULL,
  at       TEXT NOT NULL,
  ok       INTEGER,
  webdriver INTEGER,
  tz       TEXT,
  lang     TEXT,
  canvas   TEXT,
  renderer TEXT,
  ip       TEXT,
  fails    TEXT,
  raw      TEXT
);
CREATE INDEX IF NOT EXISTS idx_checks_account_at ON checks(account, at DESC);
`);

const now = () => new Date().toISOString();

// 兼容旧库：补 fp_seed 列（内核指纹种子，来自 --fingerprint=）
try {
  const cols = db.prepare('PRAGMA table_info(accounts)').all().map((c) => c.name);
  if (!cols.includes('fp_seed')) db.exec('ALTER TABLE accounts ADD COLUMN fp_seed TEXT');
  if (!cols.includes('engine')) db.exec('ALTER TABLE accounts ADD COLUMN engine TEXT');
  if (!cols.includes('cdp')) db.exec('ALTER TABLE accounts ADD COLUMN cdp TEXT');
} catch (e) {}

function upsertAccount(rec) {
  const old = getAccount(rec.account) || {};
  const row = Object.assign({
    store_id: null, platform: null, proxy: null, extra: null, headless: 0,
    status: 'running', created_at: now(),
  }, old, rec, { updated_at: now() });
  db.prepare(`
    INSERT INTO accounts (account,store_id,platform,port,proxy,tz,lang,extra,profile,headless,pid,status,created_at,updated_at,last_check_at,last_check_ok)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(account) DO UPDATE SET
      store_id=excluded.store_id, platform=excluded.platform, port=excluded.port, proxy=excluded.proxy,
      tz=excluded.tz, lang=excluded.lang, extra=excluded.extra, profile=excluded.profile,
      headless=excluded.headless, pid=excluded.pid, status=excluded.status, updated_at=excluded.updated_at
  `).run(
    row.account, row.store_id, row.platform, row.port, row.proxy, row.tz, row.lang, row.extra,
    row.profile, row.headless ? 1 : 0, row.pid || null, row.status,
    row.created_at, row.updated_at, row.last_check_at || null, row.last_check_ok ?? null
  );
  if (rec.cdp !== undefined && rec.cdp !== null) {
    db.prepare('UPDATE accounts SET cdp=? WHERE account=?').run(String(rec.cdp), rec.account);
  }
  if (rec.engine !== undefined && rec.engine !== null) {
    db.prepare('UPDATE accounts SET engine=? WHERE account=?').run(String(rec.engine), rec.account);
  }
  if (rec.fp_seed !== undefined && rec.fp_seed !== null) {
    db.prepare('UPDATE accounts SET fp_seed=? WHERE account=?').run(String(rec.fp_seed), rec.account);
  }
  return getAccount(rec.account);
}

function setStatus(account, status, pid) {
  db.prepare('UPDATE accounts SET status=?, pid=?, updated_at=? WHERE account=?')
    .run(status, pid === undefined ? null : pid, now(), account);
}

function recordCheck(account, item) {
  const p = item.probe || {};
  const fails = (item.fails || []).join('; ');
  db.prepare(`INSERT INTO checks (account,at,ok,webdriver,tz,lang,canvas,renderer,ip,fails,raw)
              VALUES (?,?,?,?,?,?,?,?,?,?,?)`).run(
    account, now(), item.ok ? 1 : 0,
    p.webdriver === true ? 1 : p.webdriver === false ? 0 : null,
    p.tz || null, (p.languages || []).join(',') || null,
    (p.canvas || {}).hash || null, (p.webgl || {}).renderer || null,
    p.ip || p.ipErr || null, fails, JSON.stringify(item)
  );
  db.prepare('UPDATE accounts SET last_check_at=?, last_check_ok=?, updated_at=? WHERE account=?')
    .run(now(), item.ok ? 1 : 0, now(), account);
}

function alive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return false; }
}

const getAccount = (a) => db.prepare('SELECT * FROM accounts WHERE account=?').get(a) || null;
const list = () => db.prepare('SELECT * FROM accounts ORDER BY account').all().map((r) => Object.assign({}, r, { alive: alive(r.pid) }));
const history = (a, limit = 20) => db.prepare('SELECT id,account,at,ok,webdriver,tz,lang,canvas,renderer,ip,fails FROM checks WHERE account=? ORDER BY id DESC LIMIT ?').all(a, limit);
const stats = () => {
  const t = db.prepare('SELECT COUNT(*) n FROM accounts').get().n;
  const run = db.prepare("SELECT COUNT(*) n FROM accounts WHERE status='running'").get().n;
  const bad = db.prepare('SELECT COUNT(*) n FROM accounts WHERE last_check_ok=0').get().n;
  const checks = db.prepare('SELECT COUNT(*) n FROM checks').get().n;
  return { db: DB_PATH, accounts: t, running: run, last_check_failed: bad, checks };
};

module.exports = { db, upsertAccount, setStatus, recordCheck, getAccount, list, history, stats, alive };

/* ---------- CLI ---------- */
if (require.main === module) {
  const argv = process.argv.slice(2);
  const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
  const cmd = argv[0] || 'stats';
  const out = cmd === 'list' ? list()
    : cmd === 'history' ? history(val('account'), parseInt(val('limit', '20'), 10))
    : cmd === 'dump' ? { stats: stats(), accounts: list(), history: val('account') ? history(val('account'), 50) : [] }
    : stats();
  console.log(JSON.stringify(out, null, 2));
}
