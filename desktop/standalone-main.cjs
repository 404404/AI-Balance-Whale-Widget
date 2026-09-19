const { app, BrowserWindow, Tray, Menu, nativeImage, screen, ipcMain, globalShortcut, shell, protocol, session, net } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { UiStateStore } = require('./ui-state-store.cjs');
const { shutdownCompanion } = require('./lifecycle.cjs');
const { externalWebUrl } = require('./external-links.cjs');
const { pathToFileURL } = require('node:url');

const root = path.resolve(__dirname, '..');
const MIN_WIDGET_SIZE = 122;
const DEFAULT_WIDGET_SIZE = 375;
const MAX_WIDGET_SIZE = 625;
const args = process.argv.slice(1);
const fixture = process.env.WHALE_DESKTOP_TEST === '1';
const layoutTest = fixture || process.argv.includes('--whale-render-test');
const explicitDataDir = args.find(value => value.startsWith('--whale-data='))?.slice('--whale-data='.length);
const productName = 'DeepSeek-Balance-Whale-Widget';
const defaultDataDir = path.join(os.homedir(), 'Library', 'Application Support', productName);
const dataDir = path.resolve(explicitDataDir || process.env.WHALE_HOME || defaultDataDir);
const startupAt = Date.now();
const startup = { revision: 'mac-standalone-0.1.0', requestedAt: Number(process.env.WHALE_LAUNCH_TIME) || startupAt, mainAt: startupAt, mode: 'standalone', phases: {} };
const markStartup = phase => { if (startup.phases[phase] == null) startup.phases[phase] = Date.now() - startup.requestedAt; };
const writeStartup = () => fs.promises.writeFile(path.join(dataDir, "startup-timings.json"), JSON.stringify(startup, null, 2)).catch(() => {});
markStartup('main');

if (!path.isAbsolute(dataDir)) app.exit(1);
protocol.registerSchemesAsPrivileged([{ scheme: 'whale', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true } }]);
fs.mkdirSync(dataDir, { recursive: true });
// Electron's own profile is separate from the user-owned whale data. Both
// paths are stable across upgrades and neither is inside the .app bundle.
app.setPath('userData', path.join(dataDir, 'electron-profile'));
fs.mkdirSync(path.join(dataDir, 'electron-profile'), { recursive: true });

const lock = app.requestSingleInstanceLock();
let window;
let tray;
let dispatcher;
let bridge;
let rendererReady = false;
let layoutReady = false;
let inputEnabled = false;
let keyboardFocus = false;
let manuallyHidden = false;
let surfaceExpanded = false;
let nativeDrag = null;
let quitting = false;
let visibilityWatchdog = null;
let frameSaveTimer = null;
let lastCursor = '';
let presents = 0;
let trustedGestureAt = 0;
let lastWidgetSize = '';
let lastLayoutDiagnostic = null;
const rendererErrors = [];
const fixtureOpenedLinks = [];
const stateFile = path.join(dataDir, 'ui-state.json');
const windowStateFile = path.join(dataDir, 'window-state.json');
const read = (file, fallback = {}) => { try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); } catch { return fallback; } };
const save = (file, value) => {
  const temp = file + '.' + process.pid + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(value, null, 2));
  fs.renameSync(temp, file);
};
const uiStore = new UiStateStore(stateFile);
const values = () => uiStore.get();
const storeValues = input => uiStore.set(input);

function validFrame(frame) {
  return frame && ['x', 'y', 'width', 'height'].every(key => Number.isFinite(Number(frame[key]))) && Number(frame.width) >= MIN_WIDGET_SIZE && Number(frame.height) >= MIN_WIDGET_SIZE;
}
function numericFrame(frame) {
  return { x: Number(frame.x), y: Number(frame.y), width: Number(frame.width), height: Number(frame.height) };
}
function workAreaFor(frame) {
  try { return screen.getDisplayMatching(frame).workArea; } catch { return screen.getPrimaryDisplay().workArea; }
}
function clampFrame(frame) {
  const area = workAreaFor(frame);
  const width = Math.min(Math.max(MIN_WIDGET_SIZE, Math.round(frame.width)), Math.max(MIN_WIDGET_SIZE, area.width));
  const height = Math.min(Math.max(MIN_WIDGET_SIZE, Math.round(frame.height)), Math.max(MIN_WIDGET_SIZE, area.height));
  return {
    x: Math.max(area.x, Math.min(Math.round(frame.x), area.x + area.width - width)),
    y: Math.max(area.y, Math.min(Math.round(frame.y), area.y + area.height - height)),
    width,
    height,
  };
}
function configuredWidgetSize() {
  const saved = read(path.join(dataDir, '.dshw-size.json'), {});
  const scale = Number(saved?.scale);
  const raw = Number.isFinite(scale) && scale >= 0.6 && scale <= 2.5 ? 250 * scale : DEFAULT_WIDGET_SIZE;
  return Math.max(MIN_WIDGET_SIZE, Math.min(MAX_WIDGET_SIZE, Math.round(raw)));
}
function defaultFrame() {
  const area = screen.getPrimaryDisplay().workArea;
  const size = configuredWidgetSize();
  const width = Math.min(size, area.width);
  const height = Math.min(size, area.height);
  return { x: area.x + area.width - width - 24, y: area.y + area.height - height - 24, width, height };
}
function initialFrame() {
  const saved = read(windowStateFile, {});
  const size = configuredWidgetSize();
  if (!validFrame(saved.frame)) return clampFrame({ ...defaultFrame(), width: size, height: size });
  const frame = numericFrame(saved.frame);
  // The native frame remembers the screen position only. Its old width/height
  // can be a 122px feedback-loop artifact, a pre-fix 248x274 frame, or an
  // expanded settings surface. Derive the startup size from the persisted
  // scale and preserve the saved bottom-right screen anchor.
  return clampFrame({
    x: frame.x + frame.width - size,
    y: frame.y + frame.height - size,
    width: size,
    height: size,
  });
}
function scheduleFrameSave() {
  if (!window || window.isDestroyed()) return;
  clearTimeout(frameSaveTimer);
  frameSaveTimer = setTimeout(() => {
    frameSaveTimer = null;
    try { save(windowStateFile, { version: 1, frame: window.getBounds(), updatedAt: new Date().toISOString() }); } catch {}
  }, 250);
}
function invalidate() { if (window && !window.isDestroyed()) { presents++; window.webContents.invalidate(); } }
function setKeyboardFocus(editing) {
  if (!window || window.isDestroyed() || keyboardFocus === editing) return;
  keyboardFocus = editing;
  if (editing) window.focus();
}
function sendCursor(force = false) {
  if (!window || window.isDestroyed() || !rendererReady || !window.isVisible()) return;
  const bounds = window.getContentBounds();
  const cursor = screen.getCursorScreenPoint();
  const point = { x: cursor.x - bounds.x, y: cursor.y - bounds.y };
  const encoded = point.x + ',' + point.y;
  if (force || encoded !== lastCursor) { lastCursor = encoded; window.webContents.send('whale-cursor', point); }
}
function visibility() {
  if (!window || window.isDestroyed()) return;
  // Do not reveal a window whose first DOM measurement still reflects the
  // 1.5 fallback while the persisted scale asks for another size. This avoids
  // a clipped first frame and makes the ready handshake include layout.
  if (rendererReady && layoutReady && !manuallyHidden) {
    if (!window.isVisible()) window.showInactive();
    if (startup.phases.interactive == null) {
      markStartup('interactive');
      writeStartup();
    }
  } else if (window.isVisible()) window.hide();
}
function show() { manuallyHidden = false; visibility(); }
function hide() { manuallyHidden = true; if (window && !window.isDestroyed()) window.hide(); }
function toggle() { manuallyHidden ? show() : hide(); }
function restoreWidget() {
  manuallyHidden = false;
  const frame = defaultFrame();
  if (window && !window.isDestroyed()) {
    surfaceExpanded = false;
    layoutReady = false;
    lastWidgetSize = '';
    window.setBounds(frame);
    window.setIgnoreMouseEvents(false);
    window.setIgnoreMouseEvents(true, { forward: true });
    scheduleFrameSave();
    window.webContents.reload();
  }
  visibility();
}
function isMainFrame(event) { return event.sender === window?.webContents && event.senderFrame === window.webContents.mainFrame; }
async function openWebLink(value, gestureRequired = true) {
  if (gestureRequired && (!trustedGestureAt || Date.now() - trustedGestureAt > 1000)) return false;
  trustedGestureAt = 0;
  let target = value;
  if (value === 'whale://widget/provider-dashboard') {
    try { target = dispatcher.whale.config.resolve().dashboardUrl; } catch { return false; }
  }
  const url = externalWebUrl(target);
  if (!url) return false;
  try {
    if (fixture) fixtureOpenedLinks.push(url);
    else await shell.openExternal(url);
    return true;
  } catch { return false; }
}
function resizeKeepingBottomRight(width, height) {
  if (!window || window.isDestroyed() || nativeDrag) return;
  const current = window.getBounds();
  const target = clampFrame({ x: current.x + current.width - width, y: current.y + current.height - height, width, height });
  if (target.width === current.width && target.height === current.height && target.x === current.x && target.y === current.y) return;
  window.setBounds(target);
  scheduleFrameSave();
  sendCursor(true);
}
function setSurface(expanded) {
  if (!window || window.isDestroyed() || surfaceExpanded === expanded) return;
  surfaceExpanded = expanded;
  if (expanded) resizeKeepingBottomRight(760, 700);
  else if (lastWidgetSize) {
    const [width, height] = lastWidgetSize.split('x').map(Number);
    resizeKeepingBottomRight(width, height);
  } else resizeKeepingBottomRight(DEFAULT_WIDGET_SIZE, DEFAULT_WIDGET_SIZE);
}
function setWidgetSize(size) {
  // The page reports its content geometry in one direction only. It must never
  // resize the native window while a native drag is in progress.
  if (surfaceExpanded || nativeDrag || !size || !Number.isFinite(size.width) || !Number.isFinite(size.height)) return;
  const width = Math.max(MIN_WIDGET_SIZE, Math.min(MAX_WIDGET_SIZE, Math.ceil(size.width)));
  const height = Math.max(MIN_WIDGET_SIZE, Math.min(MAX_WIDGET_SIZE, Math.ceil(size.height)));
  const key = width + 'x' + height;
  if (key === lastWidgetSize) return;
  lastWidgetSize = key;
  resizeKeepingBottomRight(width, height);
  if (!layoutReady && window && !window.isDestroyed()) {
    // The native content bounds after setBounds are the final geometry
    // contract. Comparing against them avoids a second screen-size formula
    // disagreeing with AppKit/Electron on a constrained display.
    const native = window.getContentBounds();
    layoutReady = Math.abs(width - native.width) <= 2 && Math.abs(height - native.height) <= 2;
  }
  writeLayoutDiagnostic();
  visibility();
}
function cursorScreenPoint(fallback) {
  try {
    const point = screen.getCursorScreenPoint();
    if (Number.isFinite(point?.x) && Number.isFinite(point?.y)) return point;
  } catch {}
  return fallback;
}
function startNativeDrag(point) {
  if (!window || window.isDestroyed() || !point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;
  const cursor = cursorScreenPoint(point);
  nativeDrag = { x: cursor.x, y: cursor.y, frame: window.getBounds() };
}
function moveNativeDrag(point) {
  if (!nativeDrag || !window || window.isDestroyed()) return;
  const cursor = cursorScreenPoint(point);
  if (!Number.isFinite(cursor.x) || !Number.isFinite(cursor.y)) return;
  const frame = nativeDrag.frame;
  window.setPosition(Math.round(frame.x + cursor.x - nativeDrag.x), Math.round(frame.y + cursor.y - nativeDrag.y));
}
function endNativeDrag() { if (nativeDrag) { nativeDrag = null; scheduleFrameSave(); writeLayoutDiagnostic(); } }
function writeLayoutDiagnostic() {
  if (!layoutTest || !lastLayoutDiagnostic || !window || window.isDestroyed()) return;
  try { save(path.join(dataDir, 'layout-diagnostic.json'), { ...lastLayoutDiagnostic, nativeFrame: window.getBounds(), at: new Date().toISOString() }); } catch {}
}
function handleDisplayChange() {
  if (!window || window.isDestroyed() || surfaceExpanded) return;
  const fixed = clampFrame(window.getBounds());
  const current = window.getBounds();
  if (JSON.stringify(fixed) !== JSON.stringify(current)) window.setBounds(fixed);
  scheduleFrameSave();
}
function importLegacyFiles() {
  const marker = path.join(dataDir, 'legacy-files-imported.json');
  if (fs.existsSync(marker) || fixture) return;
  const candidates = [
    path.join(os.homedir(), '.codex', 'whale-widget'),
    path.join(os.homedir(), '.codex', 'whale-widget', 'profiles', 'web'),
  ];
  const names = ['api-settings.json', '.dshw-size.json', '.dshw-bubble.json', 'ui-state.json'];
  const copied = [];
  for (const name of names) {
    const target = path.join(dataDir, name);
    if (fs.existsSync(target)) continue;
    for (const sourceRoot of candidates) {
      const source = path.join(sourceRoot, name);
      try {
        if (!fs.existsSync(source) || !fs.statSync(source).isFile()) continue;
        fs.copyFileSync(source, target, fs.constants.COPYFILE_EXCL);
        if (name === 'ui-state.json') storeValues(read(target, {}));
        copied.push(name);
        break;
      } catch {}
    }
  }
  try { save(marker, { version: 1, copied, at: new Date().toISOString() }); } catch {}
}

if (!lock) {
  app.quit();
} else {
  app.on('second-instance', show);
  app.on('activate', show);
  app.whenReady().then(async () => {
    markStartup('appReady');
    const { createDispatcher, UI_ORIGIN } = await import(pathToFileURL(path.join(root, 'runtime', 'dispatcher.mjs')));
    const { startBridge } = await import(pathToFileURL(path.join(root, 'runtime', 'bridge.mjs')));
    dispatcher = createDispatcher({
      dataDir,
      fetchImpl: (url, options) => net.fetch(url, options),
      onStop: () => app.quit(),
      onShow: show,
      statusInfo: () => ({ standalone: true, hostAlive: false, visible: !!window?.isVisible(), rendering: null }),
      monitor: true,
      autoRefresh: true,
    });
    markStartup('dispatcherReady');
    importLegacyFiles();
    session.defaultSession.protocol.handle('whale', async request => {
      const url = new URL(request.url);
      if (url.host !== 'widget') return new Response('', { status: 403 });
      const result = await dispatcher.dispatch(url.pathname + url.search, {
        method: request.method,
        body: ['GET', 'HEAD'].includes(request.method) ? null : Buffer.from(await request.arrayBuffer()),
        headers: Object.fromEntries(request.headers),
      });
      return new Response(request.method === 'HEAD' ? null : result.body, { status: result.status, headers: result.headers });
    });
    const frame = initialFrame();
    window = new BrowserWindow({
      ...frame,
      transparent: true,
      frame: false,
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      movable: false,
      backgroundColor: '#00000000',
      hasShadow: false,
      skipTaskbar: true,
      show: false,
      title: 'AI Balance Whale',
      webPreferences: {
        preload: path.join(__dirname, 'preload.cjs'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        backgroundThrottling: false,
        autoplayPolicy: 'no-user-gesture-required',
      },
    });
    markStartup('windowCreated');
    window.setMenuBarVisibility(false);
    window.setAlwaysOnTop(false);
    window.once('ready-to-show', () => markStartup('frameReady'));
    window.on('show', () => { invalidate(); sendCursor(true); });
    window.on('resize', () => { invalidate(); sendCursor(true); });
    window.on('move', scheduleFrameSave);
    window.on('moved', scheduleFrameSave);
    window.on('closed', () => { window = null; });
    window.webContents.on('console-message', (_event, ...args) => {
      if (!fixture) return;
      const detail = args[0];
      if (typeof detail === 'object' ? detail.level === 'error' : detail === 3) rendererErrors.push(typeof detail === 'object' ? detail.message : args[1]);
    });
    window.webContents.on('render-process-gone', (_event, details) => {
      rendererReady = false;
      layoutReady = false;
      inputEnabled = false;
      try { window.setIgnoreMouseEvents(true, { forward: true }); } catch {}
      try { save(path.join(dataDir, 'renderer-gone.json'), { at: new Date().toISOString(), reason: details?.reason || 'unknown' }); } catch {}
      if (!quitting && !window.isDestroyed()) setTimeout(() => { if (!window.isDestroyed()) window.webContents.reload(); }, 500);
    });
    window.webContents.on('did-start-loading', () => {
      rendererReady = false;
      layoutReady = false;
      inputEnabled = false;
      setKeyboardFocus(false);
      window.setIgnoreMouseEvents(true, { forward: true });
    });
    window.webContents.setWindowOpenHandler(({ url }) => { openWebLink(url).catch(() => {}); return { action: 'deny' }; });
    window.webContents.on('will-navigate', (event, url) => { if (!url.startsWith(UI_ORIGIN + '/')) event.preventDefault(); });
    session.defaultSession.setPermissionRequestHandler((_web, _permission, callback) => callback(false));

    ipcMain.on('whale-storage', event => { event.returnValue = event.sender === window?.webContents ? values() : {}; });
    ipcMain.on('whale-save-storage', (event, input) => { if (event.sender === window?.webContents) storeValues(input); });
    ipcMain.on('whale-user-gesture', event => { if (isMainFrame(event)) trustedGestureAt = Date.now(); });
    ipcMain.handle('whale-open-external', (event, url) => isMainFrame(event) ? openWebLink(url) : false);
    ipcMain.on('whale-ready', event => {
      if (event.sender !== window?.webContents) return;
      markStartup('imageAndInputReady');
      rendererReady = true;
      visibility();
      invalidate();
      sendCursor(true);
    });
    ipcMain.on('whale-interactive', (event, enabled) => {
      if (event.sender !== window?.webContents || typeof enabled !== 'boolean') return;
      // A native drag owns input until mouse-up; hover hit-test changes must
      // not toggle ignoreMouseEvents and make the window appear to jump.
      const next = nativeDrag ? true : enabled;
      if (next === inputEnabled) return;
      inputEnabled = next;
      window.setIgnoreMouseEvents(!next, { forward: true });
    });
    ipcMain.on('whale-keyboard-focus', (event, editing) => { if (event.sender === window?.webContents && typeof editing === 'boolean') setKeyboardFocus(editing); });
    ipcMain.on('whale-surface', (event, expanded) => { if (event.sender === window?.webContents && typeof expanded === 'boolean') setSurface(expanded); });
    ipcMain.on('whale-widget-size', (event, size) => { if (event.sender === window?.webContents) setWidgetSize(size); });
    ipcMain.on('whale-layout-diagnostic', (event, payload) => {
      if (!layoutTest || event.sender !== window?.webContents || !payload || typeof payload !== 'object') return;
      lastLayoutDiagnostic = payload;
      writeLayoutDiagnostic();
    });
    ipcMain.on('whale-drag-start', (event, point) => { if (event.sender === window?.webContents) startNativeDrag(point); });
    ipcMain.on('whale-drag-move', (event, point) => { if (event.sender === window?.webContents) moveNativeDrag(point); });
    ipcMain.on('whale-drag-end', event => { if (event.sender === window?.webContents) endNativeDrag(); });

    const iconPath = path.join(root, 'assets', 'DSniang1.png');
    const icon = nativeImage.createFromPath(iconPath).resize({ width: 32, height: 32 });
    if (process.platform === 'darwin' && app.dock) app.dock.setIcon(icon);
    tray = new Tray(icon);
    if (process.platform === 'darwin' && typeof tray.setTemplateImage === 'function') tray.setTemplateImage(false);
    tray.setToolTip('AI Balance Whale');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: '显示 / 隐藏小鲸鱼', click: toggle },
      { label: '打开设置', click: () => { show(); window.webContents.send('whale-settings'); } },
      { label: '恢复人偶位置', click: restoreWidget },
      { type: 'separator' },
      { label: '退出 AI Balance Whale', click: () => app.quit() },
    ]));
    tray.on('double-click', toggle);
    globalShortcut.register(process.platform === 'darwin' ? 'Command+Option+W' : 'Control+Alt+W', toggle);
    screen.on('display-metrics-changed', handleDisplayChange);
    screen.on('display-removed', handleDisplayChange);
    try {
      bridge = await startBridge(dispatcher, { dataDir });
      markStartup("bridgeReady");
    } catch (error) {
      bridge = null;
      try { save(path.join(dataDir, "bridge-error.json"), { message: String(error?.message || error).slice(0, 350), at: new Date().toISOString() }); } catch {}
      markStartup("bridgeUnavailable");
    }
    await window.loadURL(UI_ORIGIN + '/widget.html');
    markStartup('pageLoaded');
    writeStartup();
    visibilityWatchdog = setInterval(visibility, 1000);
    if (visibilityWatchdog.unref) visibilityWatchdog.unref();
    app.once('will-quit', () => {
      clearInterval(visibilityWatchdog);
      clearTimeout(frameSaveTimer);
      globalShortcut.unregisterAll();
      screen.removeListener('display-metrics-changed', handleDisplayChange);
      screen.removeListener('display-removed', handleDisplayChange);
      tray?.destroy();
    });
  }).catch(error => {
    try { save(path.join(dataDir, 'desktop-error.json'), { message: String(error.message).slice(0, 350), at: new Date().toISOString() }); } catch {}
    app.exit(1);
  });
  app.on('window-all-closed', () => { if (!quitting) app.quit(); });
  app.on('before-quit', event => {
    event.preventDefault();
    if (quitting) return;
    quitting = true;
    try { if (window && !window.isDestroyed()) { window.setIgnoreMouseEvents(true); window.hide(); } } catch {}
    let finished = false;
    const finish = () => { if (finished) return; finished = true; app.exit(0); };
    const watchdog = setTimeout(finish, 6500);
    shutdownCompanion({
      readRenderer: () => window && !window.isDestroyed() && !window.webContents.isDestroyed() && !window.webContents.isCrashed?.()
        ? window.webContents.executeJavaScript("Object.fromEntries(Object.keys(localStorage).filter(k => /^dshw[-v]/.test(k)).map(k => [k, localStorage.getItem(k)]))") : null,
      saveRenderer: storeValues,
      flushState: () => uiStore.flush(),
      closeBridge: () => bridge?.close(),
      closeDispatcher: () => dispatcher?.close(),
    }).catch(() => {}).finally(() => { clearTimeout(watchdog); finish(); });
  });
}
