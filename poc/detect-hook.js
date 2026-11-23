/* ============================================================================
 * detect-hook.js — 指纹伪造检测器（与 hook-inject.js 对照）
 * 用法：
 *   A. DevTools Console 直接粘贴执行 → 返回 {score, findings}
 *   B. CDP: Runtime.evaluate({expression: <本文件全文>, returnByValue: true})
 *   C. 挂到检测页 <script> 末尾，结果写入 window.__DETECT__
 * 设计原则：只用「证据交叉」判定，不依赖单一 flag（单一 flag 极易被针对性绕过）。
 * ========================================================================== */
(function () {
  'use strict';
  const F = [];
  const add = (id, level, msg, detail) => F.push({ id, level, msg, detail });

  /* ---------- 1. 函数完整性：toString 是否被改写 / 被 Proxy 包装 ---------- */
  const ts = Function.prototype.toString;
  const tsSrc = (() => { try { return ts.call(ts); } catch (e) { return 'ERR'; } })();
  if (!/\[native code\]\s*\}\s*$/.test(tsSrc)) {
    add('T1', 'high', 'Function.prototype.toString 自身非 native —— 注入层做了 toString 伪装', tsSrc.slice(0, 120));
  } else if (ts.name !== 'toString' || ts.length !== 0) {
    add('T1b', 'medium', 'Function.prototype.toString 的 name/length 异常（可能为 Proxy 包装）', `${ts.name}/${ts.length}`);
  }

  const suspects = {
    'canvas.toDataURL': [HTMLCanvasElement.prototype.toDataURL, 0],
    'canvas.getContext': [HTMLCanvasElement.prototype.getContext, 1],
    'ctx.getImageData': [CanvasRenderingContext2D.prototype.getImageData, 4],
    'gl.getParameter': [window.WebGLRenderingContext && WebGLRenderingContext.prototype.getParameter, 1],
    'AudioBuffer.getChannelData': [window.AudioBuffer && AudioBuffer.prototype.getChannelData, 1],
  };
  for (const [name, [fn, expectLen]] of Object.entries(suspects)) {
    if (!fn) continue;
    const src = (() => { try { return ts.call(fn); } catch (e) { return ''; } })();
    if (!/\[native code\]/.test(src)) add('T2', 'high', `${name} 非 native（JS 层被替换）`, src.slice(0, 100));
    else if (fn.length !== expectLen) add('T2b', 'medium', `${name} 参数个数异常（${fn.length}≠${expectLen}），疑似包装后伪装 native`, '');
  }

  /* ---------- 2. Canvas 噪声的确定性：3 个全新上下文必须完全一致 ---------- */
  function drawText() {
    const c = document.createElement('canvas'); c.width = 220; c.height = 60;
    const x = c.getContext('2d');
    x.textBaseline = 'top'; x.font = "14px 'Arial'";
    x.fillStyle = '#f60'; x.fillRect(90, 1, 60, 18);
    x.fillStyle = '#069'; x.fillText('detect-hook-🔍', 2, 14);
    x.fillStyle = 'rgba(102,204,0,.7)'; x.fillText('detect-hook-🔍', 4, 16);
    return c;
  }
  const a = drawText().toDataURL(), b = drawText().toDataURL(), c = drawText().toDataURL();
  if (!(a === b && b === c)) add('C1', 'high', '同一页面三次新建 canvas 结果不一致：噪声非确定性（每次读取抖动）', `len=${a.length}`);

  // 同一 canvas 连续 getImageData
  const ctx = drawText().getContext('2d');
  const h = (arr) => { let x = 0; for (let i = 0; i < arr.length; i += 997) x = (x * 31 + arr[i]) | 0; return x; };
  const i1 = h(ctx.getImageData(0, 0, 220, 60).data);
  const i2 = h(ctx.getImageData(0, 0, 220, 60).data);
  if (i1 !== i2) add('C2', 'high', '同一 canvas 连续两次 getImageData 不一致：逐次抖动', `${i1}/${i2}`);

  // toDataURL 与 getImageData 两条路径是否同源（多数 hook 只改其中一条）
  (() => {
    const cv = drawText();
    const viaURL = cv.toDataURL();
    const tmp = document.createElement('canvas'); tmp.width = 220; tmp.height = 60;
    tmp.getContext('2d').drawImage(cv, 0, 0);
    const viaImg = tmp.toDataURL();
    if (viaURL !== viaImg) add('C3', 'medium', 'toDataURL 与其像素复制路径不一致：仅部分路径被 hook', '');
  })();

  /* ---------- 3. 跨执行上下文一致性（2D 主线程 vs Worker OffscreenCanvas） ---------- */
  add('C4', 'info', 'Worker 交叉校验需异步执行，见 worker-crosscheck.js', '可选步骤');

  /* ---------- 4. WebGL：能力矩阵与 renderer 声称的硬件档位是否自洽 ---------- */
  const gl = document.createElement('canvas').getContext('webgl');
  if (gl) {
    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    const renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    const vendor = dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
    const maxTex = gl.getParameter(gl.MAX_TEXTURE_SIZE);
    const exts = gl.getSupportedExtensions() || [];
    const prec = gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT);
    const precBits = prec ? prec.precision : 0;

    if (maxTex < 4096) add('G1', 'high', `MAX_TEXTURE_SIZE=${maxTex} 与任何现代 GPU 都不符（软件光栅化/伪造）`, renderer);
    if (exts.length < 10) add('G2', 'high', `扩展数量仅 ${exts.length}，远低于真实 Chrome（常见 25~40）`, renderer);
    if (!exts.includes('WEBGL_debug_renderer_info')) add('G3', 'medium', 'WEBGL_debug_renderer_info 缺失（真实 Chrome 默认存在）', '');
    if (/Apple|NVIDIA|AMD|Intel|Mali|Adreno/i.test(String(renderer)) && precBits < 23)
      add('G4', 'medium', 'HIGH_FLOAT 精度位数与声称的桌面 GPU 不符', `precision=${precBits} renderer=${renderer}`);
    if (/SwiftShader|llvmpipe|Software|Mesa OffScreen/i.test(String(renderer)))
      add('G5', 'high', 'renderer 暴露软件渲染（极典型的环境异常）', renderer);

    // WebGL2 与 WebGL1 的 vendor/renderer 必须一致（只 hook 一者的实现会穿帮）
    const gl2 = document.createElement('canvas').getContext('webgl2');
    if (gl2) {
      const d2 = gl2.getExtension('WEBGL_debug_renderer_info');
      const r2 = d2 ? gl2.getParameter(d2.UNMASKED_RENDERER_WEBGL) : gl2.getParameter(gl2.RENDERER);
      if (r2 !== renderer) add('G6', 'high', 'WebGL1 与 WebGL2 的 renderer 不一致：只 hook 了一个上下文', `1=${renderer} 2=${r2}`);
      if (gl2.getParameter(gl2.MAX_TEXTURE_SIZE) !== maxTex) add('G6b', 'medium', 'WebGL1/2 MAX_TEXTURE_SIZE 不一致', '');
    }
  } else {
    add('G0', 'high', 'WebGL 不可用（真实桌面 Chrome 不会如此）', '');
  }

  /* ---------- 5. 平台 ↔ 字体 ↔ UA 的三方一致性 ---------- */
  const ua = navigator.userAgent;
  const fonts = (() => {
    const cx = document.createElement('canvas').getContext('2d');
    const bases = ['monospace', 'serif', 'sans-serif'];
    const m = (f) => { cx.font = '72px ' + f; return cx.measureText('mmmmmmmmmmlli').width; };
    const bw = bases.map(m);
    const probe = ['Microsoft YaHei', 'SimSun', 'SimHei', 'PingFang SC', 'Hiragino Sans GB', 'Segoe UI', 'Calibri', 'Menlo', 'Monaco', 'DejaVu Sans'];
    return probe.filter(f => bases.some((b, i) => m('"' + f + '",' + b) !== bw[i]));
  })();
  const isWin = /Windows NT/.test(ua), isMac = /Macintosh/.test(ua), isLinux = /Linux/.test(ua) && !/Android/.test(ua);
  if (isWin && fonts.includes('PingFang SC')) add('F1', 'high', 'UA 声称 Windows，却命中 macOS 专有字体 PingFang SC', fonts.join(','));
  if (isMac && (fonts.includes('Microsoft YaHei') || fonts.includes('SimSun'))) add('F1b', 'high', 'UA 声称 macOS，却命中 Windows 专有字体', fonts.join(','));
  if (isLinux && fonts.includes('Segoe UI')) add('F1c', 'medium', 'UA 声称 Linux，却命中 Segoe UI', fonts.join(','));
  if (fonts.length === 0) add('F2', 'high', '字体探针零命中：字体列表被清空/伪造', '');

  /* ---------- 6. 自动化与 CDP 痕迹 ---------- */
  if (navigator.webdriver === true) add('A1', 'high', 'navigator.webdriver=true（自动化模式）', '');
  if (navigator.plugins.length === 0) add('A2', 'high', 'navigator.plugins 为空（真实 Chrome 有 5 个内置 PDF 插件项）', '');
  if (window.outerWidth === 0 || window.outerHeight === 0) add('A3', 'medium', 'outerWidth/Height=0（典型 headless 窗口）', '');
  if (Object.keys(window).some(k => /^(cdc_|\$cdc|__playwright|__puppeteer|__nightmare|_selenium)/i.test(k)))
    add('A4', 'high', 'window 上存在自动化框架注入变量', '');
  if (typeof Notification !== 'undefined' && Notification.permission === 'denied' && !navigator.userActivation?.hasBeenActive)
    add('A5', 'low', 'Notification.permission=denied 且无用户交互（部分环境默认拒绝）', '');
  // debugger 语句耗时：CDP 附加时通常显著变长
  const t0 = performance.now(); /* eslint-disable no-debugger */ debugger; const dt = performance.now() - t0;
  if (dt > 50) add('A6', 'high', 'debugger 语句阻塞异常（CDP Debugger 已附加）', `dt=${dt.toFixed(1)}ms`);

  /* ---------- 7. 私有扩展 API 探测（紫鸟特征：chrome.superbrowser） ---------- */
  try {
    if (window.chrome && typeof chrome.superbrowser !== 'undefined')
      add('Z1', 'high', '检测到 chrome.superbrowser 私有 API —— 处于定制内核环境', Object.keys(chrome.superbrowser || {}).join(','));
    if (window.chrome && chrome.runtime && chrome.runtime.id)
      add('Z2', 'low', '页面运行在扩展上下文（chrome.runtime.id 可见）', chrome.runtime.id);
  } catch (e) {}

  /* ---------- 8. 汇总打分 ---------- */
  const weight = { high: 25, medium: 12, low: 5, info: 0 };
  const score = Math.min(100, F.reduce((s, f) => s + (weight[f.level] || 0), 0));
  const result = { score, verdict: score >= 50 ? 'HIGH_RISK' : score >= 25 ? 'SUSPICIOUS' : 'CLEAN', findings: F };
  window.__DETECT__ = result;
  console.table(F.map(f => ({ id: f.id, level: f.level, msg: f.msg })));
  console.log('%c[detect-hook] score=' + score + ' ' + result.verdict, 'font-weight:bold');
  return result;
})();
