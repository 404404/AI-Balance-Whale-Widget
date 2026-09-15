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

    // Navigation completion and the page's explicit ready handshake are
    // independent. A didFinish callback must never erase a ready message.
    private var navigationGeneration = 0
    private var navigationToken = ""
    private var activeNavigation: WKNavigation?
    private var navigationFinished = false
    private var frontendReady = false
    private var refreshRequestedForGeneration = 0
    private var pendingLayoutScript: String?
    private var pendingRenderScript: String?

    private var isLeftAttached = false
    private var isRightAttached = false
    private var bubbleVisible = false
    private var bubbleHeight: CGFloat = WhaleLayout.defaultBubbleHeight
    private var debugEvents: [(Date, String)] = []

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
            contentRect: CGRect(origin: .zero, size: WhaleLayout.baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A transparent borderless panel must not add a second rectangular
        // shadow around the SVG bubble or the transparent whale image.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = webView
        webView.frame = panel.contentView?.bounds ?? .zero
        webView.autoresizingMask = [.width, .height]
        contentController.add(self, name: "bridge")
        webView.navigationDelegate = self
        restoreFrame()
        applyPreferences()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        navigationGeneration += 1
        navigationToken = "nav-\(navigationGeneration)"
        activeNavigation = nil
        navigationFinished = false
        frontendReady = false
        refreshRequestedForGeneration = 0
        recordDebug("navigation started \(navigationToken)")

        guard let html = Bundle.main.url(forResource: "WhaleWidget", withExtension: "html") else {
            recordDebug("missing WhaleWidget.html")
            activeNavigation = webView.loadHTMLString(
                "<html><body style='background:transparent'>AI Balance Whale</body></html>",
                baseURL: nil
            )
            return
        }
        var components = URLComponents(url: html, resolvingAgainstBaseURL: false)
        components?.fragment = navigationToken
        let url = components?.url ?? html
        activeNavigation = webView.loadFileURL(
            url,
            allowingReadAccessTo: Bundle.main.resourceURL ?? html.deletingLastPathComponent()
        )
    }

    func show() { window?.orderFrontRegardless() }
    func hide() { window?.orderOut(nil) }
    var isVisible: Bool { window?.isVisible == true }

    func applyPreferences() {
        guard let panel = window else { return }
        let preferences = AppPreferences.shared
        panel.level = preferences.alwaysOnTop ? .floating : .normal
        panel.ignoresMouseEvents = preferences.mousePassthrough
        panel.collectionBehavior = preferences.allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace]
        resizeToCurrentLayout(preserveAnchor: true)
        renderCurrentState()
    }

    func resetPositionAndSize() {
        AppPreferences.shared.resetLayout()
        bubbleVisible = false
        bubbleHeight = WhaleLayout.defaultBubbleHeight
        window?.setFrame(defaultFrame(), display: true)
        clampAndSave()
        sendLayout()
        renderCurrentState()
    }

    func openSettings(page: String? = nil) {
        NotificationCenter.default.post(
            name: .aiWhaleOpenSettings,
            object: nil,
            userInfo: ["page": page ?? "general"]
        )
    }

    func refresh() { provider.refresh() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        guard acceptsMessage(body) else {
            recordDebug("ignored stale message \(type)")
            return
        }

        switch type {
        case "ready":
            frontendReady = true
            recordDebug("frontend ready \(navigationToken)")
            if navigationFinished { synchronizeFrontend() }
            if refreshRequestedForGeneration != navigationGeneration {
                refreshRequestedForGeneration = navigationGeneration
                provider.refresh()
            }
        case "refresh":
            provider.refresh()
        case "openSettings":
            openSettings(page: body["page"] as? String)
        case "toggleBubble":
            evaluate("window.__AIWhale && window.__AIWhale.toggleBubble()")
        case "restoreLayout":
            resetPositionAndSize()
        case "bubbleLayout":
            let visible = (body["visible"] as? NSNumber)?.boolValue ?? bubbleVisible
            let requestedHeight = CGFloat((body["height"] as? NSNumber)?.doubleValue ?? Double(bubbleHeight))
            bubbleVisible = visible
            bubbleHeight = min(max(requestedHeight, 120), WhaleLayout.maximumBubbleHeight)
            resizeToCurrentLayout(preserveAnchor: true)
        case "layoutMetrics":
            recordMetrics(body)
        case "openExternal":
            guard let raw = body["url"] as? String,
                  let url = URL(string: raw),
                  (url.scheme == "https" || url.scheme == "http"),
                  url.host != nil else { return }
            NSWorkspace.shared.open(url)
        case "dragMove":
            guard !AppPreferences.shared.mousePassthrough,
                  let dx = body["dx"] as? NSNumber,
                  let dy = body["dy"] as? NSNumber else { return }
            moveBy(dx: CGFloat(dx.doubleValue), dy: CGFloat(dy.doubleValue))
        case "dragEnd":
            guard (body["moved"] as? NSNumber)?.boolValue == true else { return }
            snapAndSave()
        default:
            recordDebug("ignored bridge message: \(type)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrentNavigation(navigation) else { return }
        navigationFinished = true
        recordDebug("navigation finished \(navigationToken)")
        // Do not set frontendReady=false here. The page may have sent ready
        // before WebKit delivered didFinish.
        if frontendReady { synchronizeFrontend() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard isCurrentNavigation(navigation) else { return }
        navigationFinished = false
        frontendReady = false
        recordDebug("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard isCurrentNavigation(navigation) else { return }
        navigationFinished = false
        frontendReady = false
        recordDebug("provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recordDebug("WebContent terminated; reloading")
        load()
    }

    func render(_ state: ProviderState, externalBalances: [[String: Any]] = []) {
        var buckets: [[String: Any]] = []
        for bucket in state.buckets {
            var item: [String: Any] = [
                "id": bucket.id,
                "name": bucket.windowName,
                "window": bucket.window.rawValue,
                "windowName": RateLimitPresentation.windowName(
                    for: bucket,
                    durationMinutes: bucket.windowDurationMinutes
                )
            ]
            if let used = bucket.usedPercent { item["usedPercent"] = used }
            if let remaining = bucket.remainingPercent { item["remainingPercent"] = remaining }
            if let reset = bucket.resetsAt { item["resetsAt"] = reset.timeIntervalSince1970 * 1000 }
            buckets.append(item)
        }

        let configuration = WhaleConfigurationStore.shared.snapshot()
        let appearance = configuration["appearance"] as? [String: Any] ?? [:]
        let sound = configuration["sound"] as? [String: Any] ?? [:]
        let bubble = normalizedBubble(configuration["bubble"] as? [String: Any] ?? [:])
        let roleID = appearance["roleId"] as? String
        let roleImage = roleID.flatMap {
            WhaleConfigurationStore.shared.resourceDataURL(kind: "roles", id: $0)
        } ?? "DSniang1.png"
        let pressRef = sound["press"] as? String ?? "Ya1.mp3"
        let releaseRef = sound["release"] as? String ?? "Ya2.mp3"
        let pressSound = WhaleConfigurationStore.shared.resourceDataURL(kind: "audio", id: pressRef) ?? pressRef
        let releaseSound = WhaleConfigurationStore.shared.resourceDataURL(kind: "audio", id: releaseRef) ?? releaseRef
        let object: [String: Any] = [
            "status": state.status.rawValue,
            "message": state.message,
            "email": state.email ?? NSNull(),
            "planType": state.planType ?? NSNull(),
            "lastUpdated": state.lastUpdated.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "buckets": buckets,
            "scale": AppPreferences.shared.scale,
            "soundEnabled": AppPreferences.shared.soundEnabled,
            "bubbleCloseAfterSeconds": AppPreferences.shared.bubbleCloseAfterSeconds,
            "showMenuButton": AppPreferences.shared.showMenuButton,
            "flip": isLeftAttached,
            "roleImage": roleImage,
            "soundVolume": sound["volume"] ?? 0.45,
            "pressSound": pressSound,
            "releaseSound": releaseSound,
            "bubble": bubble,
            "bubbleSteps": bubble["steps"] ?? [],
            "vendors": externalBalances
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        pendingRenderScript = "window.__AIWhale && window.__AIWhale.update(\(json))"
        flushPendingScripts()
    }

    func clampAndSave() {
        guard let panel = window, let screen = screenForPanel(panel) else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(
            max(frame.origin.x, visible.minX),
            max(visible.minX, visible.maxX - frame.width)
        )
        frame.origin.y = min(
            max(frame.origin.y, visible.minY),
            max(visible.minY, visible.maxY - frame.height)
        )
        panel.setFrame(frame, display: false)
        isLeftAttached = abs(frame.minX - visible.minX) < 1
        isRightAttached = abs(frame.maxX - visible.maxX) < 1
        AppPreferences.shared.saveFrame(frame)
    }

    func diagnostics() -> [[String: Any]] {
        debugEvents.map { ["time": $0.0.timeIntervalSince1970, "event": $0.1] }
    }

    func renderCurrentState() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        render(appDelegate.latestProviderState, externalBalances: appDelegate.latestExternalBalances)
    }

    private func restoreFrame() {
        guard let panel = window else { return }
        let saved = AppPreferences.shared.savedFrame()
        let fallback = defaultFrame()
        guard let saved,
              saved.width.isFinite, saved.height.isFinite,
              saved.width > 0, saved.height > 0 else {
            panel.setFrame(fallback, display: false)
            clampAndSave()
            return
        }

        // Old beta releases stored obsolete 248x274/410 window sizes. Migrate
        // only the position/edge anchor; calculate the current size from the
        // layout instead of trusting historical width and height.
        let newSize = currentContentSize()
        var frame = CGRect(origin: saved.origin, size: newSize)
        let screen = screenForPanel(panel, proposedFrame: saved)
        let visible = screen?.visibleFrame
        let nearRight = visible.map { abs(saved.maxX - $0.maxX) < 28 } ?? false
        let nearLeft = visible.map { abs(saved.minX - $0.minX) < 28 } ?? false
        if nearRight { frame.origin.x += saved.width - newSize.width }
        else if !nearLeft { frame.origin.x += (saved.width - newSize.width) / 2 }
        // NSWindow uses a bottom-left origin. Keep the bottom whale anchor.
        frame.origin.y = saved.maxY - newSize.height
        panel.setFrame(frame, display: false)
        clampAndSave()
    }

    private func defaultFrame() -> CGRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = currentContentSize()
        return CGRect(
            x: visible.maxX - size.width - 24,
            y: visible.minY + 24,
            width: size.width,
            height: size.height
        )
    }

    private func currentContentSize() -> CGSize {
        WhaleLayout.contentSize(
            scale: AppPreferences.shared.scale,
            bubbleVisible: bubbleVisible,
            bubbleHeight: bubbleHeight
        )
    }

    private func resizeToCurrentLayout(preserveAnchor: Bool) {
        guard let panel = window else { return }
        let old = panel.frame
        let newSize = currentContentSize()
        guard old.size != newSize else {
            sendLayout()
            return
        }

        var frame = old
        frame.size = newSize
        if preserveAnchor {
            if isRightAttached { frame.origin.x = old.maxX - newSize.width }
            else if !isLeftAttached { frame.origin.x = old.midX - newSize.width / 2 }
            // Expand upwards and keep the bottom-center whale anchor fixed.
            frame.origin.y = old.maxY - newSize.height
        }
        panel.setFrame(frame, display: false)
        clampAndSave()
        sendLayout()
    }

    private func sendLayout() {
        let scale = WhaleLayout.scale(AppPreferences.shared.scale)
        let size = currentContentSize()
        let baseHeight = size.height / max(scale, 0.01)
        pendingLayoutScript = "window.__AIWhale && window.__AIWhale.setLayout({scale:\(scale),width:\(size.width),height:\(size.height),heightBase:\(baseHeight),bubbleVisible:\(bubbleVisible)})"
        flushPendingScripts()
    }

    private func moveBy(dx: CGFloat, dy: CGFloat) {
        guard let panel = window else { return }
        var frame = panel.frame
        frame.origin.x += dx
        frame.origin.y -= dy
        panel.setFrame(frame, display: false)
    }

    private func snapAndSave() {
        guard let panel = window, let screen = screenForPanel(panel) else { return }
        guard AppPreferences.shared.snapEnabled else {
            clampAndSave()
            return
        }
        let visible = screen.visibleFrame
        var frame = panel.frame
        let threshold: CGFloat = 26
        if abs(frame.minX - visible.minX) <= threshold { frame.origin.x = visible.minX }
        if abs(frame.maxX - visible.maxX) <= threshold { frame.origin.x = visible.maxX - frame.width }
        if abs(frame.minY - visible.minY) <= threshold { frame.origin.y = visible.minY }
        if abs(frame.maxY - visible.maxY) <= threshold { frame.origin.y = visible.maxY - frame.height }
        panel.setFrame(frame, display: false)
        clampAndSave()
        renderCurrentState()
    }

    private var scriptsReady: Bool { navigationFinished && frontendReady }

    private func synchronizeFrontend() {
        sendLayout()
        flushPendingScripts()
        if pendingRenderScript == nil { renderCurrentState() }
    }

    private func flushPendingScripts() {
        guard scriptsReady else { return }
        if let script = pendingLayoutScript {
            pendingLayoutScript = nil
            evaluate(script)
        }
        if let script = pendingRenderScript {
            pendingRenderScript = nil
            evaluate(script)
        }
    }

    private func evaluate(_ script: String) {
        guard scriptsReady else { return }
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, let error else { return }
            self.recordDebug("javascript failed: \(error.localizedDescription)")
        }
    }

    private func normalizedBubble(_ raw: [String: Any]) -> [String: Any] {
        func normalize(_ rawStep: [String: Any]) -> [String: Any] {
            var step = rawStep
            if let resourceID = rawStep["resourceId"] as? String,
               let source = WhaleConfigurationStore.shared.resourceDataURL(kind: "bubbles", id: resourceID) {
                step["src"] = source
            }
            if let options = rawStep["options"] as? [[String: Any]] {
                step["options"] = options.map(normalize)
            }
            return step
        }
        var bubble = raw
        if let steps = raw["steps"] as? [[String: Any]] { bubble["steps"] = steps.map(normalize) }
        return bubble
    }

    private func acceptsMessage(_ body: [String: Any]) -> Bool {
        guard let expected = body["navigationToken"] as? String else { return false }
        return expected == navigationToken
    }

    private func isCurrentNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let activeNavigation, let navigation else { return false }
        return activeNavigation === navigation
    }

    private func recordMetrics(_ body: [String: Any]) {
        func number(_ key: String) -> String {
            guard let value = body[key] as? NSNumber else { return "?" }
            return String(format: "%.1f", value.doubleValue)
        }
        recordDebug("metrics inner=\(number("innerWidth"))x\(number("innerHeight")) whale=\(number("whaleX")),\(number("whaleY")),\(number("whaleW"))x\(number("whaleH")) bubble=\(number("bubbleX")),\(number("bubbleY")),\(number("bubbleW"))x\(number("bubbleH"))")
    }

    private func recordDebug(_ event: String) {
        debugEvents.append((Date(), event))
        if debugEvents.count > 80 { debugEvents.removeFirst(debugEvents.count - 80) }
    }

    private func screenForPanel(_ panel: NSWindow, proposedFrame: CGRect? = nil) -> NSScreen? {
        let frame = proposedFrame ?? panel.frame
        return NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

extension Notification.Name {
    static let aiWhaleOpenSettings = Notification.Name("AIWhaleOpenSettings")
}
