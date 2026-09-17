import Cocoa
import WebKit

/// A separate non-activating panel for the character context menu. Keeping it
/// out of the character WKWebView avoids clipping at the tiny widget window
/// boundary while preserving the upstream menu's visual language and actions.
final class NativeContextMenuController: NSObject, WKScriptMessageHandler {
    enum Action: String {
        case toggleBubble, refresh, settings, settingsBubble, settingsAccounts, restoreDisplay
    }

    var onAction: ((Action) -> Void)?
    private let panel: NSPanel
    private let webView: WKWebView
    private var eventMonitor: Any?
    private var lastAnchor = NSPoint.zero

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let userContent = WKUserContentController()
        configuration.userContentController = userContent
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 242, height: 294),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = webView
        webView.autoresizingMask = [.width, .height]
        userContent.add(self, name: "contextMenu")
        if let url = Bundle.main.url(forResource: "NativeContextMenu", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: Bundle.main.resourceURL ?? url.deletingLastPathComponent())
        }
    }

    deinit { close() }

    func show(at screenPoint: NSPoint, preferredScreen: NSScreen?) {
        lastAnchor = screenPoint
        position(size: panel.frame.size, screen: preferredScreen)
        panel.orderFrontRegardless()
        installEventMonitor()
    }

    func close() {
        panel.orderOut(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "contextMenu", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "size", let width = body["width"] as? NSNumber, let height = body["height"] as? NSNumber {
            let size = NSSize(width: min(max(CGFloat(width.doubleValue), 190), 360), height: min(max(CGFloat(height.doubleValue), 160), 520))
            position(size: size, screen: screenForAnchor())
            return
        }
        if type == "close" { close(); return }
        if type == "close" { close(); return }
        if type == "close" { close(); return }
        guard type == "action", let raw = body["action"] as? String, let action = Action(rawValue: raw) else { return }
        close()
        onAction?(action)
    }

    private func position(size: NSSize, screen: NSScreen?) {
        let visible = (screen ?? screenForAnchor() ?? NSScreen.main)?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        var origin = NSPoint(x: lastAnchor.x + 6, y: lastAnchor.y - size.height - 6)
        if origin.y < visible.minY { origin.y = lastAnchor.y + 6 }
        if origin.x + size.width > visible.maxX { origin.x = lastAnchor.x - size.width - 6 }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screenForAnchor() -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.contains(lastAnchor) }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.close(); return nil }
            if let eventWindow = event.window, eventWindow === self.panel { return event }
            self.close()
            return event
        }
    }
}
