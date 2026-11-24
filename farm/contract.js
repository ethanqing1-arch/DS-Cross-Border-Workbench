#!/usr/bin/env node
/* ============================================================================
 * contract.js — 农场对外契约的唯一事实源（single source of truth）
 *
 * 存在意义：平台子模式包要声明「我至少要哪个版本的 browser-farm」，装的时候要能
 * 校验；否则子模式调了旧农场没有的任务类型，报错会很难查。版本号、任务类型、
 * 引擎能力三样以前散在 gateway/server.js 里，现在只在这里定义，网关 require 它。
 *
 * 用法：
 *   node contract.js                          # 打印完整契约
 *   node contract.js check --require 1.1.0    # 版本满足性校验，退出码 0/1
 *   node contract.js engines                  # 只列引擎能力
 *   node contract.js tasks                    # 只列任务类型
 * ========================================================================== */
'use strict';
const path = require('path');

const PKG = require('./package.json');

/* 契约版本：任务形状/错误码的兼容性边界，改动不兼容时 +1 */
const CONTRACT_VERSION = 3;

/* 任务类型：网关 TASK_REGISTRY 必须全覆盖这些，多出来的算扩展 */
const TASK_TYPES = ['goto', 'eval', 'click', 'type', 'shot', 'scan', 'extract', 'wait'];

/* 引擎能力：transport 决定任务走哪条通道
 *   cdp    → driver.js --cdp <endpoint> <cmd>
 *   worker → camoufox_worker.py --task <json>（无 CDP，Playwright/Juggler）
 * tasks 为该引擎**实测可跑**的任务子集，不得为了好看填满。
 */
const ENGINE_CAPS = {
  chromium: { transport: 'cdp', tasks: TASK_TYPES.slice() },
  linux150: { transport: 'cdp', tasks: TASK_TYPES.slice() },
  chrome: { transport: 'cdp', tasks: TASK_TYPES.slice() },
  camoufox: { transport: 'worker', tasks: TASK_TYPES.slice() },
};

/* 只能由外部容器/进程提供、网关不负责 provision 的引擎 */
const ATTACH_ONLY = ['linux150'];

const VERSION = String(PKG.version || '0.0.0');

const contract = () => ({
  name: PKG.name,
  version: VERSION,
  contract_version: CONTRACT_VERSION,
  task_types: TASK_TYPES,
  engines: Object.fromEntries(Object.entries(ENGINE_CAPS).map(([k, v]) => [k, {
    transport: v.transport, tasks: v.tasks,
  }])),
  attach_only: ATTACH_ONLY,
  gateway_routes: ['/v1/health', '/v1/version', '/v1/sessions', '/v1/sessions/:sid',
    '/v1/sessions/:sid/tasks', '/v1/tasks/:id', '/v1/fingerprint/verify', '/v1/fingerprint/duplicates'],
});

/* semver 三段的朴素比较：只支持 x.y.z 数字段，够用且不引依赖 */
function parse(v) {
  const m = String(v || '').trim().match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}
function cmp(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
  return 0;
}

function check(requireVersion) {
  const want = parse(requireVersion);
  const have = parse(VERSION);
  if (!want) return { ok: false, error: `bad require version '${requireVersion}'` };
  if (!have) return { ok: false, error: `bad own version '${VERSION}'` };
  const ok = cmp(have, want) >= 0;
  return { ok, name: PKG.name, version: VERSION, required: requireVersion, contract_version: CONTRACT_VERSION };
}

module.exports = { CONTRACT_VERSION, TASK_TYPES, ENGINE_CAPS, ATTACH_ONLY, VERSION, contract, check, cmp, parse };

if (require.main === module) {
  const argv = process.argv.slice(2);
  const val = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
  const cmd = argv[0] || 'dump';
  let out;
  if (cmd === 'check') out = check(val('require', '0.0.0'));
  else if (cmd === 'engines') out = ENGINE_CAPS;
  else if (cmd === 'tasks') out = TASK_TYPES;
  else out = contract();
  console.log(JSON.stringify(out, null, 2));
  if (cmd === 'check' && !out.ok) process.exitCode = 1;
}
