import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quota = QuotaRefreshCoordinator()
    private var whaleWindow: WhaleWindowController!
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var isSleeping = false
    private(set) var latestProviderState = ProviderState()
    private(set) var latestAccounts: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        latestAccounts = WhaleConfigurationStore.shared.publicAccounts()
        quota.onAccountsUpdated = { [weak self] accounts in
            self?.latestAccounts = accounts
            self?.whaleWindow?.renderCurrentState()
            self?.settingsWindow?.refreshConnectionState()
        }
        quota.onCodexConnection = { [weak self] state in
            self?.latestProviderState = state
            self?.settingsWindow?.refreshConnectionState()
        }
        whaleWindow = WhaleWindowController()
        whaleWindow.onRefresh = { [weak self] in self?.quota.refresh() }
        whaleWindow.load()
        whaleWindow.show()
        quota.refresh()
        setupStatusItem()
        setupObservers()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, !isSleeping else { return }
            quota.refresh()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        refreshTimer?.invalidate()
        quota.stopImmediately()
        return .terminateNow
    }

    @objc private func openSettings(_ sender: Any? = nil) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(hostOwner: whaleWindow)
            controller.connectionState = { [weak self] in self?.latestProviderState ?? ProviderState() }
            controller.onAppearanceChanged = { [weak self] in
                guard let self else { return }
                whaleWindow.applyPreferences()
                whaleWindow.renderCurrentState()
                quota.refresh()
                updateMenuTitles()
            }
            controller.onConnectionChanged = { [weak self] in self?.quota.configurationChanged() }
            controller.onTestConnection = { [weak self] path, home in
                guard let self else { return }
                AppPreferences.shared.codexPath = path
                AppPreferences.shared.codexHome = home
                self.quota.configurationChanged()
            }
            controller.onRefreshAccounts = { [weak self] id in
                if let id { self?.quota.refreshAccount(id: id) } else { self?.quota.refresh() }
            }
            controller.onResetLayout = { [weak self] in self?.whaleWindow.resetPositionAndSize() }
            settingsWindow = controller
        }
        let page: String
        if let notification = sender as? Notification {
            page = notification.userInfo?["page"] as? String ?? "general"
        } else {
            page = "general"
        }
        settingsWindow?.show(page: page)
    }

    @objc private func toggleWhale(_ sender: Any? = nil) {
        if whaleWindow.isVisible { whaleWindow.hide() } else { whaleWindow.show() }
        updateMenuTitles()
    }

    @objc private func refreshNow(_ sender: Any? = nil) { quota.refresh() }

    @objc private func restoreDisplay(_ sender: Any? = nil) {
        whaleWindow.restoreDisplay()
        updateMenuTitles()
    }

    @objc private func togglePassthrough(_ sender: NSMenuItem) {
        AppPreferences.shared.mousePassthrough.toggle()
        whaleWindow.applyPreferences()
        updateMenuTitles()
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        AppPreferences.shared.alwaysOnTop.toggle()
        whaleWindow.applyPreferences()
        updateMenuTitles()
    }

    @objc private func toggleAllSpaces(_ sender: NSMenuItem) {
        AppPreferences.shared.allSpaces.toggle()
        whaleWindow.applyPreferences()
        updateMenuTitles()
    }

    @objc private func quit(_ sender: Any? = nil) { NSApp.terminate(nil) }

    func whaleWindowDiagnostics() -> [[String: Any]] { whaleWindow?.diagnostics() ?? [] }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            statusItem.button?.image = icon
            statusItem.button?.imageScaling = .scaleProportionallyDown
            statusItem.button?.title = ""
            statusItem.button?.setAccessibilityLabel("AI Balance Whale")
        } else {
            statusItem.button?.title = "🐋"
        }
        let menu = NSMenu()
        menu.addItem(menuItem("隐藏鲸鱼", #selector(toggleWhale(_:)), tag: 1))
        menu.addItem(menuItem("手动刷新额度", #selector(refreshNow(_:)), tag: 2))
        menu.addItem(.separator())
        menu.addItem(menuItem("鼠标穿透", #selector(togglePassthrough(_:)), tag: 3))
        menu.addItem(menuItem("置顶", #selector(toggleAlwaysOnTop(_:)), tag: 4))
        menu.addItem(menuItem("跨桌面 / 全屏辅助", #selector(toggleAllSpaces(_:)), tag: 5))
        menu.addItem(.separator())
        menu.addItem(menuItem("恢复人偶显示", #selector(restoreDisplay(_:)), tag: 6))
        menu.addItem(menuItem("设置…", #selector(openSettings(_:)), tag: 7))
        menu.addItem(menuItem("打开帮助", #selector(openHelp(_:)), tag: 8))
        menu.addItem(menuItem("问题反馈", #selector(openFeedback(_:)), tag: 9))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 AI Balance Whale", #selector(quit(_:)), tag: 10))
        statusItem.menu = menu
        updateMenuTitles()
    }

    private func menuItem(_ title: String, _ action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = .off
        return item
    }

    private func updateMenuTitles() {
        guard let items = statusItem?.menu?.items else { return }
        for item in items {
            switch item.tag {
            case 1: item.title = whaleWindow?.isVisible == true ? "隐藏鲸鱼" : "显示鲸鱼"
            case 3: item.state = AppPreferences.shared.mousePassthrough ? .on : .off
            case 4: item.state = AppPreferences.shared.alwaysOnTop ? .on : .off
            case 5: item.state = AppPreferences.shared.allSpaces ? .on : .off
            default: break
            }
        }
    }

    private func setupObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = true
            self?.quota.setSleeping(true)
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = false
            self?.quota.setSleeping(false)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.whaleWindow?.clampAndSave()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings(_:)), name: .aiWhaleOpenSettings, object: nil)
        NotificationCenter.default.addObserver(forName: .aiWhaleProviderConfigurationChanged, object: nil, queue: .main) { [weak self] _ in
            self?.quota.refresh()
            self?.whaleWindow?.renderCurrentState()
        }
    }

    @objc private func openHelp(_ sender: Any? = nil) { open("https://github.com/404404/AI-Balance-Whale-Widget#ai-balance-whale-macos") }
    @objc private func openFeedback(_ sender: Any? = nil) { open("https://github.com/404404/AI-Balance-Whale-Widget/issues") }
    private func open(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }
}
