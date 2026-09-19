# macOS 独立模式

## 架构

`desktop/main.cjs` 是模式选择器：

- macOS 或 `--standalone` → `desktop/standalone-main.cjs`；
- 其他情况 → `desktop/follow-main.cjs`，保留上游 Windows Codex 跟随路径。

独立宿主继续把 `assets/whale-widget.js` 作为唯一人偶/气泡/编辑器实现，通过 Electron 私有 `whale://widget` scheme 访问 `runtime/dispatcher.mjs` 提供的本地资源和 API。没有第二套点击队列、渲染器或设置存储。

独立模式不读取 `WHALE_INITIAL_HOST`，不要求 `--supervised`，不检查 `follow-config.json`，不使用 Windows 原生句柄、DPI 转换、`schtasks.exe` 或 Codex 心跳。可选的 Codex API 配置只影响余额 provider，不影响人偶启动。

## 窗口和输入

人偶使用透明、无边框、无阴影的非可调整 Electron 窗口。窗口原点和大小使用 Electron/macOS 屏幕 DIP；Retina scaleFactor 不在应用层重复换算。

上游脚本仍负责点击队列、按压/松开动画、气泡、角色命中测试和设置弹窗。独立宿主只提供几个受控 bridge 消息：

- `ready`、`interactive`、`keyboardFocus`：渲染 ready 与透明区域鼠标穿透；
- `surface`、`widgetSize`：菜单/编辑器打开时扩大窗口，关闭后按人偶几何缩回；
- `dragStart`、`dragMove`、`dragEnd`：使用 `PointerEvent.screenX/screenY` 移动原生窗口，避免窗口移动后 `clientX/clientY` 变化造成跳动。

空白区域继续通过 `setIgnoreMouseEvents(..., { forward: true })` 穿透；仅人偶、气泡、菜单和编辑器表面打开交互，不创建覆盖整个桌面的可点击层。菜单栏“恢复人偶位置”只恢复窗口位置/尺寸并重载渲染器，不触碰 API 配置、账本或用户素材。

## 生命周期

应用使用 `requestSingleInstanceLock()`。重复启动只唤起已有窗口；隐藏与退出是不同动作。渲染器异常退出时，窗口先恢复鼠标穿透并有限重载；退出时限时保存 UI 状态、关闭本应用自己的 bridge、停止余额/会话服务和删除本实例的 runtime 文件。

默认数据目录：

```text
~/Library/Application Support/DeepSeek-Balance-Whale-Widget/
├── electron-profile/       # Electron 本地 profile
├── api-settings.json       # provider 设置，不含密钥
├── .dshw-size.json         # 角色/音效/尺寸等上游设置
├── .dshw-bubble.json       # 上游气泡配置
├── whale-roles/             # 用户角色素材
├── whale-audio/             # 用户音效素材
├── whale-bubble-imgs/       # 用户气泡图片
├── ui-state.json            # 上游 localStorage 快照
├── window-state.json        # 原生窗口几何
└── runtime.json / *.sock    # 本应用自己的本地 bridge
```

`WHALE_HOME` 或 `--whale-data` 可用于开发和测试隔离。Unix socket 路径由数据目录 hash 派生；启动时只在确认旧 pid 已退出或 runtime 文件无效时清理同名残留，socket 写入后设为用户私有权限。

## 当前边界

本阶段保留上游 API 余额和本机账本口径，但不声称 ChatGPT/Codex 订阅额度。网页 Auth、Codex 窗口跟随和需要辅助功能权限的能力不在此阶段；它们必须通过后续独立适配接入，不能通过演示数据或假登录状态填充。
