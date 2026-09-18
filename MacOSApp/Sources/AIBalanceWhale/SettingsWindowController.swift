import Cocoa
import WebKit
import ServiceManagement
import UniformTypeIdentifiers
import CodexCore

final class SettingsWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    var onAppearanceChanged: (() -> Void)?
    var onConnectionChanged: (() -> Void)?
    var onRefreshAccounts: ((String?) -> Void)?
    var onCodexLogin: (() -> Void)?
    var onCodexDisconnect: (() -> Void)?
    var onResetLayout: (() -> Void)?
    var connectionState: (() -> ProviderState)?

    private let webView: WKWebView
    private let hostAdapter: WhaleHostAdapter
    private var ready = false
    private var pendingBridgeScripts: [String] = []
    private var requestedPage = "general"

    init(hostOwner: WhaleWindowController? = nil) {
        hostAdapter = WhaleHostAdapter(owner: hostOwner)
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
        controller.add(self, name: "bridge")
        view.navigationDelegate = self
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        ready = false
        pendingBridgeScripts.removeAll()
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
        if message.name == "bridge", let body = message.body as? [String: Any], let type = body["type"] as? String {
            if type == "ready" {
                ready = true
                sendPayload()
                sendPageSelection()
                let pending = pendingBridgeScripts
                pendingBridgeScripts.removeAll()
                pending.forEach { sendJavaScript($0) }
            } else if type == "hostRequest", let requestID = body["requestId"] as? String, let method = body["method"] as? String, let path = body["path"] as? String {
                let result = hostAdapter.handle(method: method, rawPath: path, body: body["body"])
                if let data = try? JSONSerialization.data(withJSONObject: result.1), let encoded = String(data: data, encoding: .utf8) {
                    let script = "window.__AIWhaleHostResponse && window.__AIWhaleHostResponse(\(json(requestID)),\(result.0),\(encoded))"
                    if ready { sendJavaScript(script) } else { pendingBridgeScripts.append(script) }
                }
            } else if type == "openExternal", let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard message.name == "settings",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            ready = true
            sendPayload()
            sendPageSelection()
            let pending = pendingBridgeScripts
            pendingBridgeScripts.removeAll()
            pending.forEach { sendJavaScript($0) }
        case "saveConfig":
            guard let config = body["config"] as? [String: Any] else { return }
            let saved = WhaleConfigurationStore.shared.save(config)
            if saved {
                applyConfiguration(WhaleConfigurationStore.shared.snapshot())
                onAppearanceChanged?()
                sendPayload()
            }
            if let requestID = body["requestId"] as? String {
                sendJavaScript("window.__AIWhaleSettings && window.__AIWhaleSettings.saveResult(\(json(requestID)),\(saved ? "true" : "false"))")
            }
        case "previewAppearance":
            guard let config = body["config"] as? [String: Any] else { return }
            applyConfiguration(config)
            onAppearanceChanged?()
        case "loginCodex", "reloginCodex":
            onCodexLogin?()
        case "disconnectCodex":
            onCodexDisconnect?()
            sendPayload()
        case "refreshCodex":
            onRefreshAccounts?("codex")
        case "resetLayout":
            WhaleConfigurationStore.shared.resetLayout()
            onResetLayout?()
            sendPayload()
        case "saveCredential":
            guard let reference = body["reference"] as? String,
                  let value = body["value"] as? String else { return }
            _ = WhaleConfigurationStore.shared.saveCredential(reference: reference, value: value)
            if let accountID = body["accountId"] as? String, !accountID.isEmpty {
                WhaleConfigurationStore.shared.updateAccount(id: accountID, patch: ["authMode": "token"])
            }
            sendPayload()
        case "refreshAccounts":
            onRefreshAccounts?(body["accountId"] as? String)
        case "addAccount":
            guard let provider = body["provider"] as? String else { return }
            var accounts = WhaleConfigurationStore.shared.accounts()
            accounts.append(AccountCatalog.makeAccount(provider: provider))
            WhaleConfigurationStore.shared.replaceAccounts(accounts)
            sendPayload()
            onAppearanceChanged?()
        case "removeAccount":
            guard let id = body["id"] as? String, !["codex", "grok", "cursor", "deepseek"].contains(id) else { return }
            var accounts = WhaleConfigurationStore.shared.accounts()
            accounts.removeAll { ($0["id"] as? String) == id }
            WhaleConfigurationStore.shared.replaceAccounts(accounts)
            sendPayload()
            onAppearanceChanged?()
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
        // The page may send ready before WebKit delivers didFinish; never clear it here.
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
        if let reminders = config["reminders"] as? [String: Any],
           let value = reminders["closeAfterSeconds"] as? NSNumber {
            preferences.bubbleCloseAfterSeconds = value.intValue
        }
        if let bubble = config["bubble"] as? [String: Any],
           let value = bubble["closeAfterSeconds"] as? NSNumber {
            preferences.bubbleCloseAfterSeconds = value.intValue
        }
        if let sound = config["sound"] as? [String: Any] {
            if let value = sound["enabled"] as? NSNumber { preferences.soundEnabled = value.boolValue }
            if let value = sound["volume"] as? NSNumber { /* persisted in configuration.json */ _ = value }
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
        var config = WhaleConfigurationStore.shared.snapshot()
        config["accounts"] = WhaleConfigurationStore.shared.publicAccounts()
        let payload: [String: Any] = [
            "config": config,
            "accounts": config["accounts"] as? [[String: Any]] ?? [],
            "providerMeta": AccountCatalog.providerMeta,
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

    private func connectionPayload() -> [String: Any] {
        let status = connectionState?()
        var result = CodexCredentialStore.shared.statusPayload()
        result["status"] = status?.status.rawValue ?? (result["status"] ?? "notLoggedIn")
        result["message"] = status?.message ?? "请在浏览器中连接 ChatGPT/Codex"
        if let email = status?.email { result["email"] = email }
        if let plan = status?.planType { result["plan"] = plan }
        if let accountID = status?.accountKey { result["accountID"] = accountID }
        if let source = status?.authSource { result["authSource"] = source }
        result["buckets"] = AccountCatalog.windows(from: status?.buckets ?? []).map(\.dictionary)
        if let updated = status?.lastUpdated { result["lastUpdated"] = updated.timeIntervalSince1970 * 1000 }
        return result
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
