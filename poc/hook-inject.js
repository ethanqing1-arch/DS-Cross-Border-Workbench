/* ============================================================================
 * hook-inject.js — 指纹 hook PoC（确定性噪声 + toString 伪装）
 * 用途：作为「JS 注入派」对照样本，用于验证紫鸟内核是内核级伪造还是 JS 注入。
 * 注入方式（三选一）：
 *   1) CDP:  Page.addScriptToEvaluateOnNewDocument({source: <本文件全文>})
 *   2) Electron preload / webContents.executeJavaScript(..., true)
 *   3) 扩展 manifest content_scripts: run_at=document_start
 * 参数全部可用占位符替换：[FINGERPRINT_ID] [WEBGL_VENDOR] [WEBGL_RENDERER] [HW_CONCURRENCY] [DEVICE_MEMORY]
 * ========================================================================== */
(function () {
  'use strict';
  if (window.__FP_HOOKED__) return;
  window.__FP_HOOKED__ = true;

  /* ---------------- 0. 配置 ---------------- */
  const CFG = {
    FINGERPRINT_ID : '[FINGERPRINT_ID]',       // 每个环境唯一，决定噪声序列
    WEBGL_VENDOR   : '[WEBGL_VENDOR]',         // 例：Google Inc. (Apple)
    WEBGL_RENDERER : '[WEBGL_RENDERER]',       // 例：ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)
    HW_CONCURRENCY : 8,
    DEVICE_MEMORY  : 8,
    NOISE_STRENGTH : 2,                        // 0..4，只改最低位附近，肉眼不可见
  };

  /* ---------------- 1. 确定性随机：同一 seed + 同一坐标 => 同一噪声 ----------------
   * 关键：噪声必须是 (x, y, seed) 的纯函数。
   * 若噪声随「每次读取」变化（Math.random），平台连续两次 getImageData 比对即可判定伪造。 */
  function hash32(x, y, seed) {
    let h = (x * 374761393 + y * 668265263 + seed * 2246822519) | 0;
    h = (h ^ (h >>> 13)) * 1274126177 | 0;
    return (h ^ (h >>> 16)) >>> 0;
  }
  function seedFromString(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return h >>> 0;
  }
  const SEED = seedFromString(CFG.FINGERPRINT_ID);

  function perturb(data, w, strength) {
    const n = strength | 0;
    if (!n) return data;
    for (let i = 0; i < data.length; i += 4) {
      const px = (i >> 2) % w, py = (i >> 2) / w | 0;
      const r = hash32(px, py, SEED);
      // 只动 RGB 的最低位，Alpha 保持不变
      data[i]     = (data[i]     & ~n) | (r & n);
      data[i + 1] = (data[i + 1] & ~n) | ((r >>> 8) & n);
      data[i + 2] = (data[i + 2] & ~n) | ((r >>> 16) & n);
    }
    return data;
  }

  /* ---------------- 2. toString 伪装（把被改函数还原成 native 形态） ---------------- */
  const nativeText = new WeakMap();
  const origToString = Function.prototype.toString;
  function markNative(fn, as) {
    try { Object.defineProperty(fn, 'name', { value: as || fn.name, configurable: true }); } catch (e) {}
    nativeText.set(fn, 'function ' + (as || fn.name) + '() { [native code] }');
    return fn;
  }
  function maskToString() {
    const patched = function toString() {
      const s = nativeText.get(this);
      return typeof s === 'string' ? s : origToString.call(this);
    };
    markNative(patched, 'toString');
    nativeText.set(patched, 'function toString() { [native code] }');
    Object.defineProperty(Function.prototype, 'toString', {
      value: patched, writable: true, configurable: true, enumerable: false,
    });
  }

  /* ---------------- 3. Canvas ---------------- */
  const C = HTMLCanvasElement.prototype;
  const origGetContext = C.getContext;
  const origToDataURL  = C.toDataURL;
  const origToBlob     = C.toBlob;
  const origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
  const origPutImageData = CanvasRenderingContext2D.prototype.putImageData;

  CanvasRenderingContext2D.prototype.getImageData = markNative(function getImageData(x, y, w, h) {
    const img = origGetImageData.apply(this, arguments);
    try { perturb(img.data, w, CFG.NOISE_STRENGTH); } catch (e) {}
    return img;
  }, 'getImageData');

  function noisyCanvas(canvas) {
    // 复制到离屏 canvas，施加同一噪声函数后再导出，保证 toDataURL 与 getImageData 同源
    const w = canvas.width, h = canvas.height;
    if (!w || !h || w * h > 4e6) return canvas;             // 大图跳过，避免卡顿
    const off = document.createElement('canvas');
    off.width = w; off.height = h;
    const octx = off.getContext('2d');
    octx.drawImage(canvas, 0, 0);
    const img = origGetImageData.call(octx, 0, 0, w, h);
    perturb(img.data, w, CFG.NOISE_STRENGTH);
    origPutImageData.call(octx, img, 0, 0);
    return off;
  }
  C.toDataURL = markNative(function toDataURL() {
    try { return origToDataURL.apply(noisyCanvas(this), arguments); }
    catch (e) { return origToDataURL.apply(this, arguments); }
  }, 'toDataURL');
  if (origToBlob) {
    C.toBlob = markNative(function toBlob(cb) {
      const rest = Array.prototype.slice.call(arguments, 1);
      try { return origToBlob.apply(noisyCanvas(this), [cb].concat(rest)); }
      catch (e) { return origToBlob.apply(this, arguments); }
    }, 'toBlob');
  }

  /* ---------------- 4. WebGL vendor / renderer ---------------- */
  const GL = window.WebGLRenderingContext && WebGLRenderingContext.prototype;
  const GL2 = window.WebGL2RenderingContext && WebGL2RenderingContext.prototype;
  function patchGL(proto) {
    if (!proto) return;
    const orig = proto.getParameter;
    proto.getParameter = markNative(function getParameter(p) {
      if (p === 37445) return CFG.WEBGL_VENDOR;      // UNMASKED_VENDOR_WEBGL
      if (p === 37446) return CFG.WEBGL_RENDERER;    // UNMASKED_RENDERER_WEBGL
      return orig.call(this, p);
    }, 'getParameter');
  }
  patchGL(GL); patchGL(GL2);

  /* ---------------- 5. AudioContext ---------------- */
  if (window.AudioBuffer) {
    const origGCD = AudioBuffer.prototype.getChannelData;
    AudioBuffer.prototype.getChannelData = markNative(function getChannelData() {
      const d = origGCD.apply(this, arguments);
      // 采样级噪声：同一 buffer 重复读取结果一致
      for (let i = 0; i < d.length; i += 97) {
        d[i] = d[i] + (hash32(i, 7, SEED) % 1000) / 1e9;
      }
      return d;
    }, 'getChannelData');
  }

  /* ---------------- 6. navigator 硬件属性 ---------------- */
  function defineGetter(proto, prop, value) {
    try {
      Object.defineProperty(proto, prop, {
        get: markNative(function () { return value; }, 'get ' + prop),
        configurable: true, enumerable: true,
      });
    } catch (e) {}
  }
  defineGetter(Navigator.prototype, 'hardwareConcurrency', CFG.HW_CONCURRENCY);
  defineGetter(Navigator.prototype, 'deviceMemory', CFG.DEVICE_MEMORY);
  defineGetter(Navigator.prototype, 'webdriver', false);

  maskToString();

  /* ---------------- 7. 自检 ---------------- */
  window.__FP_SELFTEST__ = function () {
    const draw = () => {
      const c = document.createElement('canvas'); c.width = 200; c.height = 50;
      const x = c.getContext('2d'); x.font = "14px 'Arial'";
      x.fillStyle = '#069'; x.fillText('hook-selftest', 2, 20); return c;
    };
    const a = draw().toDataURL(), b = draw().toDataURL(), c = draw().toDataURL();
    const g = document.createElement('canvas').getContext('webgl');
    const dbg = g && g.getExtension('WEBGL_debug_renderer_info');
    return {
      stable: a === b && b === c,
      canvasLen: a.length,
      renderer: dbg ? g.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null,
      hw: navigator.hardwareConcurrency,
      webriver: navigator.webdriver,
      toStringNative: /\[native code\]/.test(Function.prototype.toString.call(HTMLCanvasElement.prototype.toDataURL)),
      toStringSelfNative: /\[native code\]/.test(Function.prototype.toString.call(Function.prototype.toString)),
    };
  };
})();
