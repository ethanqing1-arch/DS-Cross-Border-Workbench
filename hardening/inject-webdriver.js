/* inject-webdriver.js — can_webdriver 补偿载荷（在 document_start、每个 frame 执行）
 * 目标：把 navigator.webdriver 从 true 改回 false，同时保持
 *   - descriptor 形态（Navigator.prototype 上的 accessor、configurable/enumerable=true、无 setter）
 *   - Function.prototype.toString 对自身与所有被改函数返回 [native code]
 * 注意：单靠本载荷只能覆盖「被执行到的 Realm」。iframe / Worker 是独立 Realm，
 *       必须由 CDP Page.addScriptToEvaluateOnNewDocument（对所有 frame 生效）或
 *       扩展 content_scripts all_frames 来保证覆盖 —— 见 cdp-compensate.js 的 self-test。
 */
(() => {
  'use strict';
  const w = window;
  if (w.__WD_PATCHED__) return;
  w.__WD_PATCHED__ = true;

  const origTS = Function.prototype.toString;
  const nativeText = new WeakMap();

  const mark = (fn, name) => {
    try { Object.defineProperty(fn, 'name', { value: name, configurable: true }); } catch (e) {}
    nativeText.set(fn, 'function ' + name + '() { [native code] }');
    return fn;
  };

  // 1) navigator.webdriver -> false
  try {
    const d = Object.getOwnPropertyDescriptor(Navigator.prototype, 'webdriver');
    if (!d || typeof d.get === 'function') {
      const getter = mark(function () { return false; }, 'get webdriver');
      Object.defineProperty(Navigator.prototype, 'webdriver', {
        get: getter, set: undefined, configurable: true, enumerable: true,
      });
    }
  } catch (e) {}

  // 2) toString 自掩蔽（含自身）
  const patched = mark(function toString() {
    const s = nativeText.get(this);
    return typeof s === 'string' ? s : origTS.call(this);
  }, 'toString');
  nativeText.set(patched, 'function toString() { [native code] }');
  try {
    Object.defineProperty(Function.prototype, 'toString', {
      value: patched, writable: true, configurable: true, enumerable: false,
    });
  } catch (e) {}

  // 3) 自检钩子：供 CDP 侧读取覆盖情况
  w.__WD_SELFTEST__ = () => ({
    webdriver: navigator.webdriver,
    ts: (() => { try { return Function.prototype.toString.call(Function.prototype.toString); } catch (e) { return 'ERR'; } })(),
    desc: (() => {
      const d = Object.getOwnPropertyDescriptor(Navigator.prototype, 'webdriver');
      return d ? { get: typeof d.get, set: typeof d.set, configurable: d.configurable, enumerable: d.enumerable } : null;
    })(),
  });
})();
