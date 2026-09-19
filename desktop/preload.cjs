const { contextBridge, ipcRenderer } = require('electron');
const saved = ipcRenderer.sendSync('whale-storage');
try { for (const [key, value] of Object.entries(saved)) if (localStorage.getItem(key) == null) localStorage.setItem(key, value); } catch {}
let trustedClickAt = 0;
for (const eventName of ['click', 'auxclick']) document.addEventListener(eventName, event => {
  if (!event.isTrusted || (event.button !== 0 && event.button !== 1)) return;
  trustedClickAt = Date.now(); ipcRenderer.send('whale-user-gesture');
}, true);
contextBridge.exposeInMainWorld('whaleDesktop', {
  ready: () => ipcRenderer.send('whale-ready'),
  keyboardFocus: value => ipcRenderer.send('whale-keyboard-focus', !!value),
  interactive: value => ipcRenderer.send('whale-interactive', !!value),
  onCursor: callback => ipcRenderer.on('whale-cursor', (_event, point) => callback(point)),
  save: values => ipcRenderer.send('whale-save-storage', values),
  openExternal: value => {
    if (!trustedClickAt || Date.now() - trustedClickAt > 1000 || !navigator.userActivation.isActive || typeof value !== 'string') return Promise.resolve(false);
    trustedClickAt = 0;
    return ipcRenderer.invoke('whale-open-external', value);
  },
  testMode: process.argv.includes('--whale-render-test'),
  standalone: process.platform === 'darwin' || process.argv.includes('--standalone'),
  surface: expanded => ipcRenderer.send('whale-surface', !!expanded),
  widgetSize: size => {
    if (!size || typeof size !== 'object') return;
    ipcRenderer.send('whale-widget-size', { width: Number(size.width), height: Number(size.height) });
  },
  layoutDiagnostic: value => {
    if (value && typeof value === 'object') ipcRenderer.send('whale-layout-diagnostic', value);
  },
  dragStart: point => ipcRenderer.send('whale-drag-start', { x: Number(point?.x), y: Number(point?.y) }),
  dragMove: point => ipcRenderer.send('whale-drag-move', { x: Number(point?.x), y: Number(point?.y) }),
  dragEnd: () => ipcRenderer.send('whale-drag-end'),
});
ipcRenderer.on('whale-settings', () => window.dispatchEvent(new Event('whale-open-settings')));
