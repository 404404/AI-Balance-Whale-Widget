import Foundation
import XCTest
import WebKit

@MainActor
final class WidgetWebViewTests: XCTestCase {
    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        var onFailure: ((Error) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFailure?(error)
        }
    }

    func testPackagedWidgetHasVisibleWhaleAcrossLayoutsAndFallback() async throws {
        let resourceRoot = try makeResourceRoot()
        let html = resourceRoot.appendingPathComponent("WhaleWidget.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: html.path), "missing WhaleWidget.html at \(html.path)")

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 420),
            configuration: WKWebViewConfiguration()
        )
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        let loaded = expectation(description: "WhaleWidget.html loaded")
        delegate.onFinish = { loaded.fulfill() }
        delegate.onFailure = { error in
            XCTFail("WKWebView failed to load: \(error)")
            loaded.fulfill()
        }

        webView.loadFileURL(html, allowingReadAccessTo: resourceRoot)
        await fulfillment(of: [loaded], timeout: 10)
        try await waitForJavaScript(webView)

        for scale in [0.65, 1.0, 1.6] {
            _ = try await evaluate(webView, "window.__AIWhale.setLayout({scale:\(scale), heightBase:184})")
            try await Task.sleep(nanoseconds: 80_000_000)
            let metrics = try await widgetMetrics(webView)
            assertVisible(metrics, expectedHeight: 184 * scale, label: "compact scale \(scale)")
            print("WHALE_WEBKIT_GEOMETRY compact scale=\(scale) app=\(rect(metrics, "app")) whale=\(rect(metrics, "whale")) computedHeight=\(metrics["computedHeight"] ?? "?")")
        }

        _ = try await evaluate(webView, "window.__AIWhale.update({status:'ready',buckets:[{name:'Codex',remainingPercent:72}]}); window.__AIWhale.toggleBubble(); window.__AIWhale.setLayout({scale:1,heightBase:346})")
        try await Task.sleep(nanoseconds: 180_000_000)
        let expanded = try await widgetMetrics(webView)
        assertVisible(expanded, expectedHeight: 346, label: "expanded bubble")
        XCTAssertEqual(expanded["bubbleVisible"] as? Bool, true)
        XCTAssertGreaterThan(rectValue(expanded, "bubble", "height"), 0)
        print("WHALE_WEBKIT_GEOMETRY expanded app=\(rect(expanded, "app")) whale=\(rect(expanded, "whale")) bubble=\(rect(expanded, "bubble"))")

        _ = try await evaluate(webView, "window.__AIWhale.toggleBubble(); window.__AIWhale.setLayout({scale:1,heightBase:184})")
        try await Task.sleep(nanoseconds: 100_000_000)
        let collapsed = try await widgetMetrics(webView)
        assertVisible(collapsed, expectedHeight: 184, label: "collapsed bubble")
        XCTAssertEqual(collapsed["bubbleVisible"] as? Bool, false)
        print("WHALE_WEBKIT_GEOMETRY collapsed app=\(rect(collapsed, "app")) whale=\(rect(collapsed, "whale"))")

        _ = try await evaluate(webView, "window.__AIWhale.update({roleImage:'missing-custom-role.png'})")
        try await waitForImage(webView)
        let fallback = try await widgetMetrics(webView)
        XCTAssertEqual(fallback["imageComplete"] as? Bool, true)
        XCTAssertGreaterThan(fallback["naturalWidth"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(fallback["naturalHeight"] as? Double ?? 0, 0)
        XCTAssertTrue((fallback["imageSource"] as? String ?? "").hasSuffix("/DSniang1.png"))
        print("WHALE_WEBKIT_IMAGE fallback source=\(fallback["imageSource"] ?? "?") natural=\(fallback["naturalWidth"] ?? "?")x\(fallback["naturalHeight"] ?? "?")")
    }

    private func widgetMetrics(_ webView: WKWebView) async throws -> [String: Any] {
        let script = """
        (function () {
          var app = document.getElementById('app');
          var whale = document.getElementById('whale');
          var bubble = document.getElementById('bubble');
          function rect(el) {
            var r = el.getBoundingClientRect();
            return {x:r.x, y:r.y, width:r.width, height:r.height,
              minX:r.left, maxX:r.right, minY:r.top, maxY:r.bottom};
          }
          function visibleAncestors(el) {
            var node = el;
            while (node) {
              var style = getComputedStyle(node);
              if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
              if (node === app) break;
              node = node.parentElement;
            }
            return true;
          }
          return {
            computedHeight: getComputedStyle(app).height,
            app: rect(app),
            whale: rect(whale),
            bubble: rect(bubble),
            bubbleVisible: getComputedStyle(bubble).visibility === 'visible',
            ancestorsVisible: visibleAncestors(whale),
            imageComplete: whale.complete,
            naturalWidth: whale.naturalWidth,
            naturalHeight: whale.naturalHeight,
            imageDisplay: getComputedStyle(whale).display,
            imageSource: whale.currentSrc || whale.src
          };
        }())
        """
        return try await evaluate(webView, script) as? [String: Any] ?? [:]
    }

    private func assertVisible(_ metrics: [String: Any], expectedHeight: Double, label: String) {
        XCTAssertGreaterThan(rectValue(metrics, "app", "height"), 0, label)
        XCTAssertEqual(rectValue(metrics, "app", "height"), expectedHeight, accuracy: 1.5, label)
        let app = metrics["app"] as? [String: Any] ?? [:]
        let whale = metrics["whale"] as? [String: Any] ?? [:]
        XCTAssertGreaterThan(rectValue(metrics, "whale", "width"), 0, label)
        XCTAssertGreaterThan(rectValue(metrics, "whale", "height"), 0, label)
        XCTAssertGreaterThanOrEqual(whale["minX"] as? Double ?? -1, (app["minX"] as? Double ?? 0) - 1, label)
        XCTAssertLessThanOrEqual(whale["maxX"] as? Double ?? -1, (app["maxX"] as? Double ?? 0) + 1, label)
        XCTAssertGreaterThanOrEqual(whale["minY"] as? Double ?? -1, (app["minY"] as? Double ?? 0) - 1, label)
        XCTAssertLessThanOrEqual(whale["maxY"] as? Double ?? -1, (app["maxY"] as? Double ?? 0) + 1, label)
        XCTAssertEqual(metrics["imageComplete"] as? Bool, true, label)
        XCTAssertGreaterThan(metrics["naturalWidth"] as? Double ?? 0, 0, label)
        XCTAssertGreaterThan(metrics["naturalHeight"] as? Double ?? 0, 0, label)
        XCTAssertEqual(metrics["imageDisplay"] as? String, "block", label)
        XCTAssertEqual(metrics["ancestorsVisible"] as? Bool, true, label)
        XCTAssertTrue((metrics["computedHeight"] as? String ?? "").hasSuffix("px"), label)
    }

    private func rect(_ metrics: [String: Any], _ key: String) -> String {
        let value = metrics[key] as? [String: Any] ?? [:]
        return String(format: "%.1fx%.1f@%.1f,%.1f",
                      value["width"] as? Double ?? 0,
                      value["height"] as? Double ?? 0,
                      value["x"] as? Double ?? 0,
                      value["y"] as? Double ?? 0)
    }

    private func rectValue(_ metrics: [String: Any], _ key: String, _ field: String) -> Double {
        let value = metrics[key] as? [String: Any] ?? [:]
        return value[field] as? Double ?? 0
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value as Any)
                }
            }
        }
    }

    private func waitForJavaScript(_ webView: WKWebView) async throws {
        for _ in 0..<20 {
            let ready = try await evaluate(webView, "Boolean(window.__AIWhale)")
            if (ready as? Bool) == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("WhaleWidget JavaScript bridge did not become ready")
    }

    private func waitForImage(_ webView: WKWebView) async throws {
        for _ in 0..<30 {
            let metrics = try await widgetMetrics(webView)
            if (metrics["imageComplete"] as? Bool) == true,
               (metrics["naturalWidth"] as? Double ?? 0) > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("whale image did not become ready")
    }

    private func makeResourceRoot() throws -> URL {
        let fileManager = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["WHALE_WIDGET_RESOURCE_ROOT"] {
            let url = URL(fileURLWithPath: raw)
            guard fileManager.fileExists(atPath: url.appendingPathComponent("WhaleWidget.html").path) else {
                throw NSError(domain: "WidgetWebViewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "WHALE_WIDGET_RESOURCE_ROOT is incomplete"])
            }
            return url
        }

        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.deletingLastPathComponent()
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("AIWhale-WebKit-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: packageRoot.appendingPathComponent("Resources/WhaleWidget.html"), to: tempRoot.appendingPathComponent("WhaleWidget.html"))
        for name in ["DSniang1.png", "Ya1.mp3", "Ya2.mp3"] {
            let source = sourceRoot.appendingPathComponent("assets").appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: tempRoot.appendingPathComponent(name))
            }
        }
        return tempRoot
    }
}
