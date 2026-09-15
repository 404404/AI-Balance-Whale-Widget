import Cocoa
import WebKit
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    var onAppearanceChanged: (() -> Void)?
    var onConnectionChanged: (() -> Void)?
    var onTestConnection: ((String, String) -> Void)?
    var onResetLayout: (() -> Void)?
    var connectionState: (() -> ProviderState)?

    private let webView: WKWebView
    private var ready = false
    private var requestedPage = "general"

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        webView = view

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Balance Whale 设置"
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = view
        super.init(window: window)

        view.autoresizingMask = [.width, .height]
        controller.add(self, name: "settings")
        view.navigationDelegate = self
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        guard let url = Bundle.main.url(forResource: "Settings", withExtension: "html") else {
            webView.loadHTMLString("<html><body>缺少 Settings.html</body></html>", baseURL: nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.resourceURL ?? url.deletingLastPathComponent())
    }

    func refreshConnectionState() { sendPayload() }

    func show(page: String = "general") {
        requestedPage = page
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if ready { sendPageSelection() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "settings",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            ready = true
            sendPayload()
            sendPageSelection()
        case "saveConfig":
            guard let config = body["config"] as? [String: Any] else { return }
            WhaleConfigurationStore.shared.save(config)
            applyConfiguration(config)
            onAppearanceChanged?()
            sendPayload()
        case "previewAppearance":
            guard let config = body["config"] as? [String: Any] else { return }
            applyConfiguration(config)
            onAppearanceChanged?()
        case "saveConnection":
            let path = selectedPath(from: body)
            let home = (body["home"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let preferences = AppPreferences.shared
            let changed = preferences.codexPath != path || preferences.codexHome != home
            preferences.codexPath = path
            preferences.codexHome = home
            if changed { onConnectionChanged?() }
            sendPayload()
        case "testConnection":
            let path = selectedPath(from: body)
            let home = (body["home"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            AppPreferences.shared.codexPath = path
            AppPreferences.shared.codexHome = home
            onTestConnection?(path, home)
        case "redetectConnection":
            AppPreferences.shared.codexPath = ""
            onConnectionChanged?()
            sendPayload()
        case "chooseCodex":
            chooseCodexExecutable()
        case "chooseCodexHome":
            chooseCodexHome()
        case "resetLayout":
            WhaleConfigurationStore.shared.resetLayout()
            onResetLayout?()
            sendPayload()
        case "saveCredential":
            guard let reference = body["reference"] as? String,
                  let value = body["value"] as? String else { return }
            _ = WhaleConfigurationStore.shared.saveCredential(reference: reference, value: value)
            sendPayload()
        case "importResource":
            guard let kind = body["kind"] as? String,
                  let name = body["name"] as? String,
                  let base64 = body["base64"] as? String else { return }
            _ = WhaleConfigurationStore.shared.importResource(kind: kind, name: name, base64: base64)
            sendPayload()
        case "deleteResource":
            guard let kind = body["kind"] as? String, let id = body["id"] as? String else { return }
            _ = WhaleConfigurationStore.shared.deleteResource(kind: kind, id: id)
            sendPayload()
        case "previewResource":
            guard let kind = body["kind"] as? String, let id = body["id"] as? String else { return }
            let dataURL = WhaleConfigurationStore.shared.resourceDataURL(kind: kind, id: id)
            sendJavaScript("window.__AIWhaleSettings && window.__AIWhaleSettings.preview(\(json(dataURL ?? "")))")
        case "backupConfig":
            guard let url = WhaleConfigurationStore.shared.backupConfiguration() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case "restoreConfig":
            restoreConfiguration()
        case "openExternal":
            guard let raw = body["url"] as? String, let url = URL(string: raw),
                  url.scheme == "https", ["github.com"].contains(url.host?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ready = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ready = false
    }

    private func applyConfiguration(_ config: [String: Any]) {
        let preferences = AppPreferences.shared
        if let layout = config["layout"] as? [String: Any] {
            if let value = layout["scale"] as? NSNumber { preferences.scale = value.doubleValue }
            if let value = layout["alwaysOnTop"] as? NSNumber { preferences.alwaysOnTop = value.boolValue }
            if let value = layout["allSpaces"] as? NSNumber { preferences.allSpaces = value.boolValue }
            if let value = layout["mousePassthrough"] as? NSNumber { preferences.mousePassthrough = value.boolValue }
            if let value = layout["launchAtLogin"] as? NSNumber {
                preferences.launchAtLogin = value.boolValue
                updateLoginItem(enabled: value.boolValue)
            }
        }
        if let appearance = config["appearance"] as? [String: Any] {
            if let value = appearance["snapEnabled"] as? NSNumber { preferences.snapEnabled = value.boolValue }
            if let value = appearance["showMenuButton"] as? NSNumber { preferences.showMenuButton = value.boolValue }
        }
        if let bubble = config["bubble"] as? [String: Any],
           let value = bubble["closeAfterSeconds"] as? NSNumber {
            preferences.bubbleCloseAfterSeconds = value.intValue
        }
        if let sound = config["sound"] as? [String: Any],
           let value = sound["enabled"] as? NSNumber {
            preferences.soundEnabled = value.boolValue
        }
    }

    private func restoreConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard WhaleConfigurationStore.shared.importConfiguration(from: url) else { return }
        applyConfiguration(WhaleConfigurationStore.shared.snapshot())
        onAppearanceChanged?()
        sendPayload()
    }

    private func sendPayload() {
        guard ready else { return }
        let connection = connectionPayload()
        let payload: [String: Any] = [
            "config": WhaleConfigurationStore.shared.snapshot(),
            "templates": ProviderTemplates.all,
            "resources": WhaleConfigurationStore.shared.allResources(),
            "app": [
                "version": Bundle.main.object(forInfoDictionaryKey: "AIAppReleaseTag") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知",
                "connection": connection,
                "diagnostics": diagnostics()
            ]
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: encoded, encoding: .utf8) {
            sendJavaScript("window.__AIWhaleSettings && window.__AIWhaleSettings.update(\(jsonString))")
        }
        if let path = connection["resolvedPath"] as? String, !cliVersionProbeCompleted.contains(path) {
            cliVersionProbeCompleted.insert(path)
            CodexLocator.version(at: URL(fileURLWithPath: path)) { [weak self] version in
                guard let self else { return }
                if let version { self.cliVersionCache[path] = version }
                self.sendPayload()
            }
        }
    }

    private func sendPageSelection() {
        sendJavaScript("window.__AIWhaleSettings && window.__AIWhaleSettings.selectPage(\(json(requestedPage)))")
    }

    private func sendJavaScript(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error { NSLog("AI Balance Whale settings JavaScript failed: %@", error.localizedDescription) }
        }
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "null" }
        return String(encoded.dropFirst().dropLast())
    }

    private var cliVersionCache: [String: String] = [:]
    private var cliVersionProbeCompleted = Set<String>()

    private func selectedPath(from body: [String: Any]) -> String {
        let raw = (body["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body["pathMode"] as? String) == "auto" ? "" : raw
    }

    private func connectionPayload() -> [String: Any] {
        let preferences = AppPreferences.shared
        let status = connectionState?()
        var result = CodexLocator.connectionInfo(
            configuredPath: preferences.codexPath,
            configuredHome: preferences.codexHome
        )
        let resolvedPath = result["resolvedPath"] as? String
        result["home"] = result["effectiveHome"] ?? ""
        result["message"] = status?.message ?? (resolvedPath == nil ? "未找到可执行的 codex" : "已找到 codex，等待测试连接")
        result["status"] = status?.status.rawValue ?? "idle"
        if let email = status?.email { result["account"] = email }
        if let version = status?.cliVersion { result["version"] = version }
        else if let resolvedPath, let version = cliVersionCache[resolvedPath] { result["version"] = version }
        return result
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else {
            return
        }
        AppPreferences.shared.codexPath = url.path
        onConnectionChanged?()
        sendPayload()
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppPreferences.shared.codexHome = url.path
        onConnectionChanged?()
        sendPayload()
    }

    private func diagnostics() -> [[String: Any]] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.whaleWindowDiagnostics()
    }

    private func updateLoginItem(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {}
    }
}
