import Cocoa
import WebKit
import CodexCore

final class WhalePanel: NSPanel {
    var onMouseDown: ((NSEvent) -> Bool)?
    var onMouseDragged: ((NSEvent) -> Bool)?
    var onMouseUp: ((NSEvent) -> Bool)?
    var onRightMouseDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if onMouseDown?(event) == true { return }
        case .leftMouseDragged:
            if onMouseDragged?(event) == true { return }
        case .leftMouseUp:
            if onMouseUp?(event) == true { return }
        case .rightMouseDown:
            if onRightMouseDown?(event) == true { return }
        default:
            break
        }
        super.sendEvent(event)
    }

}

private struct WhaleGeometryMetrics {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

private struct NativeDragSession {
    let startScreen: NSPoint
    let originalFrame: CGRect
    var moved = false
}

final class WhaleWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    var onRefresh: (() -> Void)?
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
    private var pendingHostResponseScripts: [String] = []

    private var isLeftAttached = false
    private var isRightAttached = false
    private var bubbleVisible = false
    private var bubbleHeight: CGFloat = WhaleLayout.defaultBubbleHeight
    private var debugEvents: [(Date, String)] = []
    private var lastWhaleMetrics: WhaleGeometryMetrics?
    private var lastMenuButtonMetrics: WhaleGeometryMetrics?
    private var nativeDragSession: NativeDragSession?
    private var lastSentLayoutKey: String?
    private lazy var hostAdapter = WhaleHostAdapter(owner: self)
    private lazy var contextMenu = NativeContextMenuController()
    // The upstream bubble is rendered inside the widget WebView, but its
    // measured height participates in the native frame.  It is not an
    // "embedded compact" overlay: opening it grows the frame upward.
    private let usesEmbeddedUpstreamBubble = false

    init() {
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
        panel.onMouseDown = { [weak self] event in self?.handleNativeMouseDown(event) ?? false }
        panel.onMouseDragged = { [weak self] event in self?.handleNativeMouseDragged(event) ?? false }
        panel.onMouseUp = { [weak self] event in self?.handleNativeMouseUp(event) ?? false }
        panel.onRightMouseDown = { [weak self] event in self?.handleNativeRightMouseDown(event) ?? false }
        contentController.add(self, name: "bridge")
        webView.navigationDelegate = self
        contextMenu.onAction = { [weak self] action in self?.performContextMenuAction(action) }
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
        pendingHostResponseScripts.removeAll()
        recordDebug("navigation started \(navigationToken)")

        let builtinWhale = Bundle.main.url(forResource: "DSniang1", withExtension: "png")
        let htmlResource = Bundle.main.url(forResource: "WhaleWidget", withExtension: "html")
        recordDebug("resources html=" + String(htmlResource != nil) + " builtinWhale=" + String(builtinWhale != nil))
        guard let html = htmlResource else {
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

    /// Recover only the widget presentation state. Account, Codex and user content
    /// preferences are deliberately left untouched.
    func restoreDisplay() {
        AppPreferences.shared.mousePassthrough = false
        bubbleVisible = false
        bubbleHeight = WhaleLayout.defaultBubbleHeight
        window?.setFrame(defaultFrame(), display: true)
        clampAndSave()
        applyPreferences()
        if !scriptsReady {
            load()
        } else {
            sendLayout()
            renderCurrentState()
        }
        show()
        recordDebug("display restored")
    }

    func openSettings(page: String? = nil) {
        NotificationCenter.default.post(
            name: .aiWhaleOpenSettings,
            object: nil,
            userInfo: ["page": page ?? "general"]
        )
    }

    func refresh() { onRefresh?() }

    func bubbleConfigurationDidChange(_ configuration: [String: Any]) {
        // The same canonical upstreamBubble object is sent to the desktop
        // renderer and is persisted by WhaleConfigurationStore. It never falls
        // back to the legacy simplified bubble field after a successful save.
        renderCurrentState()
        recordDebug("bubble configuration applied")
    }

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
                refresh()
            }
        case "hostRequest":
            handleHostRequest(body)
        case "refresh":
            refresh()
        case "openContextMenu":
            let screenPoint: NSPoint
            if let x = body["x"] as? NSNumber, let y = body["y"] as? NSNumber {
                screenPoint = panel.convertPoint(toScreen: NSPoint(x: x.doubleValue, y: panel.frame.height - y.doubleValue))
            } else {
                screenPoint = NSPoint(x: panel.frame.maxX - 8, y: panel.frame.midY)
            }
            contextMenu.show(at: screenPoint, preferredScreen: screenForPanel(panel))
        case "openSettings":
            openSettings(page: body["page"] as? String)
        case "toggleBubble":
            evaluate("window.__AIWhale && window.__AIWhale.toggleBubble()")
        case "restoreLayout":
            resetPositionAndSize()
        case "restoreDisplay":
            restoreDisplay()
        case "bubbleLayout":
            let visible = (body["visible"] as? NSNumber)?.boolValue ?? bubbleVisible
            let requestedHeight = CGFloat((body["height"] as? NSNumber)?.doubleValue ?? Double(bubbleHeight))
            let changed = visible != bubbleVisible || abs(requestedHeight - bubbleHeight) > 0.5
            bubbleVisible = visible
            bubbleHeight = min(max(requestedHeight, 120), WhaleLayout.maximumBubbleHeight)
            recordMetrics(body)
            if changed { resizeToCurrentLayout(preserveAnchor: true) }
        case "layoutMetrics":
            recordMetrics(body)
        case "imageState":
            recordImageState(body)
        case "openExternal":
            guard let raw = body["url"] as? String,
                  let url = URL(string: raw),
                  (url.scheme == "https" || url.scheme == "http"),
                  url.host != nil else { return }
            NSWorkspace.shared.open(url)
        case "dragMove":
            recordDebug("ignored legacy dragMove")
        case "dragEnd":
            recordDebug("ignored legacy dragEnd")
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
        renderCurrentState()
    }

    func renderCurrentState() {
        let store = WhaleConfigurationStore.shared
        let configuration = store.snapshot()
        let appearance = configuration["appearance"] as? [String: Any] ?? [:]
        let sound = configuration["sound"] as? [String: Any] ?? [:]
        let bubble = configuration["bubble"] as? [String: Any] ?? [:]
        let steps = (bubble["steps"] as? [[String: Any]]) ?? AccountCatalog.defaultBubbleSteps()
        let accounts = store.publicAccounts()
        let roleID = appearance["roleId"] as? String
        let roleImage = roleID.flatMap { store.resourceDataURL(kind: "roles", id: $0) } ?? "DSniang1.png"
        let pressRef = sound["press"] as? String ?? "Ya1.mp3"
        let releaseRef = sound["release"] as? String ?? "Ya2.mp3"
        let pressSound = store.resourceDataURL(kind: "audio", id: pressRef) ?? pressRef
        let releaseSound = store.resourceDataURL(kind: "audio", id: releaseRef) ?? releaseRef
        let revision = steps.map { ($0["id"] as? String) ?? "" }.joined(separator: "/") + "/" + String(accounts.count)
        let object: [String: Any] = [
            "accounts": accounts,
            "bubble": ["steps": steps, "advanceOnClick": bubble["advanceOnClick"] ?? true, "closeAfterSeconds": bubble["closeAfterSeconds"] ?? 0],
            "bubbleSteps": steps,
            "bubbleRevision": revision,
            "scale": AppPreferences.shared.scale,
            "soundEnabled": AppPreferences.shared.soundEnabled,
            "bubbleCloseAfterSeconds": AppPreferences.shared.bubbleCloseAfterSeconds,
            "showMenuButton": AppPreferences.shared.showMenuButton,
            "flip": isLeftAttached,
            "roleImage": roleImage,
            "soundVolume": sound["volume"] ?? 0.45,
            "pressSound": pressSound,
            "releaseSound": releaseSound
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let payloadJSON = String(data: data, encoding: .utf8) else { return }
        pendingRenderScript = "window.__AIWhale && window.__AIWhale.update(\(payloadJSON))"
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
        frame.origin.y = saved.minY
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
            bubbleVisible: usesEmbeddedUpstreamBubble ? false : bubbleVisible,
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
            frame.origin.y = old.minY
        }
        panel.setFrame(frame, display: false)
        clampAndSave()
        sendLayout()
    }

    private func sendLayout() {
        let scale = WhaleLayout.scale(AppPreferences.shared.scale)
        let size = currentContentSize()
        let baseHeight = size.height / max(scale, 0.01)
        let key = String(format: "%.3f/%.1f/%.1f/%@", scale, size.width, size.height, bubbleVisible ? "1" : "0")
        guard key != lastSentLayoutKey else { return }
        lastSentLayoutKey = key
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
        if !pendingHostResponseScripts.isEmpty {
            let scripts = pendingHostResponseScripts
            pendingHostResponseScripts.removeAll()
            scripts.forEach { evaluate($0) }
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
        if let x = body["whaleX"] as? NSNumber,
           let y = body["whaleY"] as? NSNumber,
           let width = body["whaleW"] as? NSNumber,
           let height = body["whaleH"] as? NSNumber {
            lastWhaleMetrics = WhaleGeometryMetrics(x: CGFloat(x.doubleValue), y: CGFloat(y.doubleValue), width: CGFloat(width.doubleValue), height: CGFloat(height.doubleValue))
        }
        if let x = body["menuX"] as? NSNumber,
           let y = body["menuY"] as? NSNumber,
           let width = body["menuW"] as? NSNumber,
           let height = body["menuH"] as? NSNumber {
            lastMenuButtonMetrics = WhaleGeometryMetrics(x: CGFloat(x.doubleValue), y: CGFloat(y.doubleValue), width: CGFloat(width.doubleValue), height: CGFloat(height.doubleValue))
        }
        recordDebug("metrics inner=\(number("innerWidth"))x\(number("innerHeight")) whale=\(number("whaleX")),\(number("whaleY")),\(number("whaleW"))x\(number("whaleH")) bubble=\(number("bubbleX")),\(number("bubbleY")),\(number("bubbleW"))x\(number("bubbleH"))")
    }

    private func handleNativeMouseDown(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == 0,
              !AppPreferences.shared.mousePassthrough,
              let point = localDOMPoint(for: event),
              isWhalePoint(point),
              !isMenuButtonPoint(point) else { return false }
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        nativeDragSession = NativeDragSession(startScreen: screenPoint, originalFrame: panel.frame)
        evaluate("window.__AIWhale && window.__AIWhale.nativePointerDown && window.__AIWhale.nativePointerDown()")
        recordDebug("native pointer down")
        return true
    }

    private func handleNativeMouseDragged(_ event: NSEvent) -> Bool {
        guard var session = nativeDragSession else { return false }
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        let dx = screenPoint.x - session.startScreen.x
        let dy = screenPoint.y - session.startScreen.y
        if hypot(dx, dy) >= 3 { session.moved = true }
        nativeDragSession = session
        guard session.moved else { return true }
        var frame = session.originalFrame
        frame.origin.x += dx
        frame.origin.y += dy
        panel.setFrame(frame, display: false)
        return true
    }

    private func handleNativeMouseUp(_ event: NSEvent) -> Bool {
        guard let session = nativeDragSession else { return false }
        nativeDragSession = nil
        evaluate("window.__AIWhale && window.__AIWhale.nativePointerUp && window.__AIWhale.nativePointerUp(\(session.moved ? "true" : "false"))")
        if session.moved { snapAndSave() }
        recordDebug(session.moved ? "native drag ended" : "native click ended")
        return true
    }

    private func handleNativeRightMouseDown(_ event: NSEvent) -> Bool {
        guard !AppPreferences.shared.mousePassthrough,
              let point = localDOMPoint(for: event), isWhalePoint(point) else { return false }
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        contextMenu.show(at: screenPoint, preferredScreen: screenForPanel(panel))
        recordDebug("native context menu opened")
        return true
    }

    private func performContextMenuAction(_ action: NativeContextMenuController.Action) {
        switch action {
        case .toggleBubble:
            evaluate("window.__AIWhale && window.__AIWhale.toggleBubble()")
        case .refresh:
            refresh()
        case .settings:
            openSettings(page: "general")
        case .settingsBubble:
            openSettings(page: "bubbles")
        case .settingsAccounts:
            openSettings(page: "accounts")
        case .restoreDisplay:
            restoreDisplay()
        }
    }

    private func localDOMPoint(for event: NSEvent) -> NSPoint? {
        guard let contentView = panel.contentView else { return nil }
        let local = contentView.convert(event.locationInWindow, from: nil)
        let bounds = contentView.bounds
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    private func isWhalePoint(_ point: NSPoint) -> Bool {
        let bounds = panel.contentView?.bounds ?? .zero
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let metrics = lastWhaleMetrics ?? WhaleGeometryMetrics(
            x: bounds.width * 0.129,
            y: bounds.height * 0.054,
            width: bounds.width * 0.742,
            height: bounds.height * 0.946
        )
        return point.x >= metrics.x && point.x <= metrics.x + metrics.width &&
            point.y >= metrics.y && point.y <= metrics.y + metrics.height
    }

    private func isMenuButtonPoint(_ point: NSPoint) -> Bool {
        guard let metrics = lastMenuButtonMetrics, metrics.width > 0, metrics.height > 0 else { return false }
        return point.x >= metrics.x && point.x <= metrics.x + metrics.width &&
            point.y >= metrics.y && point.y <= metrics.y + metrics.height
    }

    private func recordImageState(_ body: [String: Any]) {
        let complete = (body["complete"] as? NSNumber)?.boolValue ?? false
        let width = (body["naturalWidth"] as? NSNumber)?.intValue ?? 0
        let height = (body["naturalHeight"] as? NSNumber)?.intValue ?? 0
        let fallback = (body["fallback"] as? NSNumber)?.boolValue ?? false
        recordDebug("image complete=\(complete) natural=\(width)x\(height) fallback=\(fallback)")
    }

    private func handleHostRequest(_ body: [String: Any]) {
        guard let requestID = body["requestId"] as? String,
              let method = body["method"] as? String,
              let path = body["path"] as? String else { return }
        let result = hostAdapter.handle(method: method, rawPath: path, body: body["body"])
        guard let data = try? JSONSerialization.data(withJSONObject: result.1),
              let payloadJSON = String(data: data, encoding: .utf8) else { return }
        let script = "window.__AIWhaleHostResponse && window.__AIWhaleHostResponse(\(json(requestID)),\(result.0),\(payloadJSON))"
        if scriptsReady { evaluate(script) } else { pendingHostResponseScripts.append(script) }
    }
    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "null" }
        return String(encoded.dropFirst().dropLast())
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
    static let aiWhaleProviderConfigurationChanged = Notification.Name("AIWhaleProviderConfigurationChanged")
}
