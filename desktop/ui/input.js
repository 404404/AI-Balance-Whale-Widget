(() => {
  'use strict';
  const bridge = window.whaleDesktop, rendering = window.WhaleRendering;
  if (!bridge || !rendering) return;
  const pet = document.querySelector('.dshwv-img'), root = document.querySelector('.dshwv-root');
  const failedRoleSources = new Set();
  let point = { x: -1, y: -1 }, heldPointer = null, releaseEpoch = 0, interactive = false, keyboardFocus = false, ready = false, lastStorage = '', surfaceExpanded = false, lastWidgetSize = '', lastDiagnosticKey = '';
  const standalone = bridge.standalone === true;
  const testMode = bridge.testMode === true;
  const surfaces = 'dialog[open],.dshwv-menu,.dshwv-menu-btn,.dshwv-rolelist,.dshwv-audiolist,[class*="mask"],.dshwv-qedit,.dshwv-usagepanel,.dshwv-custmenu,.dshwv-custbtn,.dshwv-tplhelp,.dshwv-fxinfo,.dshwv-fxicon,#toast:not([hidden])';
  const keyboardSurfaces = 'dialog[open],.dshwv-menu,.dshwv-rolelist,.dshwv-audiolist,[class*="mask"],.dshwv-qedit,.dshwv-usagepanel,.dshwv-custmenu';
  function visible(el) { return el.checkVisibility({ opacityProperty: true, visibilityProperty: true }); }
  function contains(el, p) { const r = el.getBoundingClientRect(); return p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom; }
  function hit(p) {
    if ([...document.querySelectorAll('dialog[open]')].some(visible)) return true;
    for (const el of document.querySelectorAll(surfaces)) if (visible(el) && contains(el, p)) return true;
    const target = document.elementFromPoint(p.x, p.y);
    if (target?.closest('.dshwv-pop-open') && !target.closest('[inert]')) return true;
    return visible(pet) && rendering.hitCache.hit(pet, p.x, p.y, rendering.mirrorScale(root) < 0);
  }
  function update() {
    const next = heldPointer !== null || hit(point);
    if (next !== interactive) { interactive = next; bridge.interactive(next); }
  }
  function updateKeyboardFocus() {
    // Menu fades start at opacity 0 and end without a DOM mutation. Use whether
    // the surface accepts input, so keyboard activation follows open/close now.
    const next = [...document.querySelectorAll(keyboardSurfaces)].some(el =>
      el.checkVisibility({ visibilityProperty: true }) && getComputedStyle(el).pointerEvents !== 'none');
    if (next !== keyboardFocus) { keyboardFocus = next; bridge.keyboardFocus(next); }
  }
  function updateSurface() {
    if (!standalone) return;
    const next = [...document.querySelectorAll(surfaces)].some(el =>
      el.checkVisibility({ opacityProperty: true, visibilityProperty: true }) && getComputedStyle(el).pointerEvents !== 'none');
    if (next !== surfaceExpanded) { surfaceExpanded = next; bridge.surface(next); }
  }
  function reportWidgetSize() {
    if (!standalone || !root) return;
    const rect = root.getBoundingClientRect();
    const width = Math.max(root.offsetWidth || 0, Math.abs(rect.width || 0));
    const height = Math.max(root.offsetHeight || 0, Math.abs(rect.height || 0));
    const key = Math.round(width) + 'x' + Math.round(height);
    if (width <= 0 || height <= 0) return;
    if (key !== lastWidgetSize) {
      lastWidgetSize = key;
      bridge.widgetSize({ width, height });
    }
    if (testMode && key !== lastDiagnosticKey) {
      lastDiagnosticKey = key;
      const style = getComputedStyle(root);
      const image = pet.getBoundingClientRect();
      const html = document.documentElement.getBoundingClientRect();
      bridge.layoutDiagnostic({
        viewport: { width: window.innerWidth, height: window.innerHeight, scrollWidth: document.documentElement.scrollWidth, scrollHeight: document.documentElement.scrollHeight },
        root: { left: rect.left, top: rect.top, width: rect.width, height: rect.height, display: style.display, visibility: style.visibility, opacity: style.opacity, overflow: style.overflow },
        image: { left: image.left, top: image.top, width: image.width, height: image.height, complete: pet.complete, naturalWidth: pet.naturalWidth, naturalHeight: pet.naturalHeight, display: getComputedStyle(pet).display, visibility: getComputedStyle(pet).visibility, opacity: getComputedStyle(pet).opacity },
        html: { left: html.left, top: html.top, width: html.width, height: html.height },
        scale: Number.parseFloat(style.getPropertyValue('--dshw-scale')) || null,
      });
    }
  }
  function track(e) { point = { x: e.clientX, y: e.clientY }; update(); }
  // Electron forwards mousemove while ignoring input on Windows; pointermove alone is insufficient.
  document.addEventListener('mousemove', track, true);
  document.addEventListener('pointermove', track, true);
  document.addEventListener('pointerdown', e => {
    ++releaseEpoch;
    point = { x: e.clientX, y: e.clientY };
    // The widget's earlier capture listener may already accept this press and
    // start the squish animation. Its pending pointer capture is authoritative:
    // testing the now-moving alpha again must not discard the accepted gesture.
    let accepted = false;
    try { accepted = root.hasPointerCapture(e.pointerId); } catch {}
    if (accepted || hit(point)) heldPointer = e.pointerId;
    update();
  }, true);
  function release(e) {
    if (e?.clientX !== undefined) point = { x: e.clientX, y: e.clientY };
    const epoch = ++releaseEpoch;
    // Finish the application's pointerup/capture handlers before changing the
    // native window's input flags. A pressed/turning sprite may miss this pixel.
    requestAnimationFrame(() => { if (epoch === releaseEpoch) { heldPointer = null; update(); } });
  }
  document.addEventListener('pointerup', release, true);
  document.addEventListener('pointercancel', release, true);
  document.addEventListener('lostpointercapture', release, true);
  window.addEventListener('blur', () => { ++releaseEpoch; heldPointer = null; point = { x: -1, y: -1 }; update(); });
  bridge.onCursor(p => {
    // Preserve the real pointer during a captured drag; native fallback only discovers hover.
    if (heldPointer === null) {
      point = p; update();
      window.dispatchEvent(new CustomEvent('whale-hover', { detail: p }));
    }
  });
  rendering.onFrame(update);
  // Layout ownership is deliberately one-way in standalone mode: ResizeObserver
  // and the native resize event report geometry; mutation/animation frames only
  // update hit testing and rendering. This prevents a window-resize -> DOM
  // mutation -> window-resize feedback loop.
  const request = () => { updateKeyboardFocus(); updateSurface(); rendering.presentFor(); };
  new MutationObserver(request).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'src', 'open', 'hidden', 'inert'] });
  document.addEventListener('transitionrun', e => {
    if (e.target.closest('.dshwv-root,.dshwv-position')) rendering.presentFor(600);
  }, true);
  window.addEventListener('resize', () => { reportWidgetSize(); rendering.presentFor(220); });
  if (standalone && typeof ResizeObserver === 'function') new ResizeObserver(reportWidgetSize).observe(root);
  async function prepare() {
    if (!pet.complete) return;
    if (!pet.naturalWidth) { fallbackRole(); return; }
    const source = pet.currentSrc || pet.src;
    await rendering.hitCache.prepare(source);
    if (!pet.complete || !pet.naturalWidth || (pet.currentSrc || pet.src) !== source) return;
    if (!ready) { ready = true; bridge.ready(); }
    reportWidgetSize();
    request();
  }
  function fallbackRole() {
    const source = pet.currentSrc || pet.src;
    if (!source || failedRoleSources.has(source)) return;
    failedRoleSources.add(source);
    window.dispatchEvent(new CustomEvent('whale-role-fallback', { detail: { src: source, reason: 'decode-failed' } }));
  }
  pet.addEventListener('load', prepare);
  pet.addEventListener('error', fallbackRole);
  prepare();
  function save() {
    const values = Object.fromEntries(Object.keys(localStorage).filter(k => /^dshw[-v]/.test(k)).map(k => [k, localStorage.getItem(k)]));
    const encoded = JSON.stringify(values);
    if (encoded !== lastStorage) { lastStorage = encoded; bridge.save(values); }
  }
  // A hidden companion has no editable surfaces. Keep the last snapshot rather
  // than repeatedly serializing localStorage while Codex is minimized.
  setInterval(() => { if (!document.hidden) save(); }, 800);
  document.addEventListener('visibilitychange', save);
  window.addEventListener('beforeunload', save);
  request();
})();
