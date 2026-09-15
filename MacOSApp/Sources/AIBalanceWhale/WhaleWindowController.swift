import Cocoa
import WebKit
import CodexCore

final class WhalePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WhaleWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    let provider: CodexAppServerClient
    private let panel: WhalePanel
    private let webView: WKWebView
    private var hasLoaded = false

    init(provider: CodexAppServerClient) {
        self.provider = provider
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        webView = view
        panel = WhalePanel(
            contentRect: CGRect(x: 0, y: 0, width: 248, height: 274),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = webView
        contentController.add(self, name: "bridge")
        webView.navigationDelegate = self
        restoreFrame()
        applyPreferences()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        if let html = Bundle.main.url(forResource: "WhaleWidget", withExtension: "html") {
            let resources = Bundle.main.resourceURL ?? html.deletingLastPathComponent()
            webView.loadFileURL(html, allowingReadAccessTo: resources)
        } else {
            webView.loadHTMLString("<html><body style='background:transparent'>AI Balance Whale</body></html>", baseURL: nil)
        }
    }

    func show() {
        guard let panel = window else { return }
        panel.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    var isVisible: Bool { window?.isVisible == true }

    func applyPreferences() {
        guard let panel = window else { return }
        let preferences = AppPreferences.shared
        panel.level = preferences.alwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = preferences.mousePassthrough
        panel.collectionBehavior = preferences.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace]
        renderCurrentState()
    }

    func openSettings() {
        NotificationCenter.default.post(name: .aiWhaleOpenSettings, object: nil)
    }

    func refresh() { provider.refresh() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            hasLoaded = true
            renderCurrentState()
            provider.refresh()
        case "refresh":
            provider.refresh()
        case "openSettings":
            openSettings()
        case "dragMove":
            guard let dx = body["dx"] as? NSNumber, let dy = body["dy"] as? NSNumber else { return }
            moveBy(dx: CGFloat(dx.doubleValue), dy: CGFloat(dy.doubleValue))
        case "dragEnd":
            snapAndSave()
        default:
            // The bridge intentionally has no file, shell, URL, or arbitrary RPC message.
            break
        }
    }

    private func renderCurrentState() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        render(appDelegate.latestProviderState)
    }

    func render(_ state: ProviderState) {
        guard hasLoaded || webView.url != nil else { return }
        var buckets: [[String: Any]] = []
        for bucket in state.buckets {
            var item: [String: Any] = [
                "id": bucket.id,
                "name": bucket.windowName,
                "window": bucket.window.rawValue,
                "windowName": RateLimitPresentation.windowName(for: bucket, durationMinutes: bucket.windowDurationMinutes),
            ]
            if let used = bucket.usedPercent { item["usedPercent"] = used }
            if let remaining = bucket.remainingPercent { item["remainingPercent"] = remaining }
            if let reset = bucket.resetsAt { item["resetsAt"] = reset.timeIntervalSince1970 * 1000 }
            buckets.append(item)
        }
        var object: [String: Any] = [
            "status": state.status.rawValue,
            "message": state.message,
            "buckets": buckets,
            "scale": AppPreferences.shared.scale,
            "soundEnabled": AppPreferences.shared.soundEnabled,
            "flip": isLeftAttached,
        ]
        if let email = state.email { object["email"] = email }
        if let planType = state.planType { object["planType"] = planType }
        if let updated = state.lastUpdated { object["lastUpdated"] = updated.timeIntervalSince1970 * 1000 }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__AIWhale && window.__AIWhale.update(\(json));", completionHandler: nil)
    }

    private var isLeftAttached = false

    private func restoreFrame() {
        guard let panel = window else { return }
        let fallback = CGRect(x: 0, y: 0, width: 248, height: 274)
        let saved = AppPreferences.shared.savedFrame() ?? fallback
        panel.setFrame(saved, display: false)
        clampAndSave()
    }

    private func moveBy(dx: CGFloat, dy: CGFloat) {
        guard let panel = window, !AppPreferences.shared.mousePassthrough else { return }
        var frame = panel.frame
        frame.origin.x += dx
        frame.origin.y -= dy
        panel.setFrame(frame, display: false)
    }

    private func snapAndSave() {
        guard let panel = window else { return }
        let screen = screenForPanel(panel)
        let visible = screen.visibleFrame
        var frame = panel.frame
        let threshold: CGFloat = 26
        if abs(frame.minX - visible.minX) <= threshold { frame.origin.x = visible.minX; isLeftAttached = true }
        if abs(frame.maxX - visible.maxX) <= threshold { frame.origin.x = visible.maxX - frame.width; isLeftAttached = false }
        if abs(frame.minY - visible.minY) <= threshold { frame.origin.y = visible.minY }
        if abs(frame.maxY - visible.maxY) <= threshold { frame.origin.y = visible.maxY - frame.height }
        panel.setFrame(frame, display: false)
        clampAndSave()
        renderCurrentState()
    }

    func clampAndSave() {
        guard let panel = window else { return }
        let screen = screenForPanel(panel)
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        panel.setFrame(frame, display: false)
        AppPreferences.shared.saveFrame(frame)
    }

    private func screenForPanel(_ panel: NSWindow) -> NSScreen {
        NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

extension Notification.Name {
    static let aiWhaleOpenSettings = Notification.Name("AIWhaleOpenSettings")
}
