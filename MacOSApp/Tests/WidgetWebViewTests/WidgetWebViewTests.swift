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

    private final class SettingsBridge: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var receivedTypes: [String] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  let webView else { return }
            receivedTypes.append(type)
            if type == "ready" {
                let payload: [String: Any] = [
                    "config": [
                        "layout": ["scale": 1.0],
                        "appearance": ["snapEnabled": true, "showMenuButton": true],
                        "sound": ["enabled": true],
                        "bubble": ["steps": [["id": "step-dash", "modules": [["type": "dashboard"]]]]],
                        "accounts": [["id": "codex", "name": "Codex", "provider": "codex", "kind": "subscription", "enabled": true, "authMode": "demo", "windows": [["id": "5h", "label": "5 小时", "remainPct": 62, "usedPct": 38]]]],
                        "reminders": ["enabled": true, "threshold": 15],
                        "records": [:]
                    ],
                    "accounts": [["id": "codex", "name": "Codex", "provider": "codex", "kind": "subscription", "enabled": true, "authMode": "demo", "windows": [["id": "5h", "label": "5 小时", "remainPct": 62, "usedPct": 38]]]],
                    "providerMeta": ["codex": ["label": "Codex / ChatGPT", "help": "test", "tokenHint": "本机 Codex 登录态"]],
                    "templates": [],
                    "resources": ["roles": [], "bubbles": [], "audio": []],
                    "app": ["version": "test", "build": "test", "connection": [
                        "resolvedPath": "/opt/homebrew/bin/codex",
                        "effectiveHome": "/Users/test/.codex",
                        "configPath": "/Users/test/.codex/config.toml",
                        "configExists": false,
                        "status": "idle",
                    ], "diagnostics": []]
                ]
                evaluate(webView, functionName: "window.__AIWhaleSettings.update", arguments: [payload])
                return
            }
            guard type == "hostRequest",
                  let requestID = body["requestId"] as? String,
                  let path = body["path"] as? String else { return }
            var response: [String: Any] = ["ok": true]
            if path.contains("/bubble.json") {
                response["config"] = ["v": 1, "items": [], "lib": [], "tapAdvance": false]
            } else if path.contains("/size.json") {
                response["scale"] = 1.0
                response["sound"] = true
                response["soundSet"] = "duck"
                response["vol"] = 0.45
            } else if path.contains("/roles.json") {
                response["roles"] = []
            } else if path.contains("/bubble-imgs.json") {
                response["images"] = []
            } else if path.contains("/audio.json") {
                response["groups"] = []
                response["fragments"] = []
            } else if path.contains("/usage-settings.json") {
                response["settings"] = [:]
            } else if path.contains("/usage-records.json") {
                response["records"] = []
            }
            evaluate(webView, functionName: "window.__AIWhaleHostResponse", arguments: [requestID, 200, response])
        }

        private func evaluate(_ webView: WKWebView, functionName: String, arguments: [Any]) {
            let encoded = arguments.compactMap { value -> String? in
                // NSJSONSerialization requires an array/object at the top
                // level on this SDK. Wrap scalar bridge arguments and remove
                // the wrapper so request IDs and HTTP status codes are valid
                // JavaScript literals too.
                guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                      let json = String(data: data, encoding: .utf8),
                      json.count >= 2 else { return nil }
                return String(json.dropFirst().dropLast())
            }
            guard encoded.count == arguments.count else { return }
            webView.evaluateJavaScript("\(functionName)(\(encoded.joined(separator: ",")))", completionHandler: nil)
        }
    }

    func testPackagedSettingsMountsUpstreamEditorDirectly() async throws {
        let resourceRoot = try makeResourceRoot()
        let settings = resourceRoot.appendingPathComponent("Settings.html")
        let configuration = WKWebViewConfiguration()
        let bridge = SettingsBridge()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__AIWhaleTestErrors=[];window.addEventListener('error',function(e){window.__AIWhaleTestErrors.push(String(e.message||e.error||'error'))},true)",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.add(bridge, name: "settings")
        configuration.userContentController.add(bridge, name: "bridge")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 920, height: 680), configuration: configuration)
        bridge.webView = webView
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        let loaded = expectation(description: "Settings.html loaded")
        delegate.onFinish = { loaded.fulfill() }
        delegate.onFailure = { error in XCTFail("settings WKWebView failed: \(error)"); loaded.fulfill() }
        webView.loadFileURL(settings, allowingReadAccessTo: resourceRoot)
        await fulfillment(of: [loaded], timeout: 10)

        for _ in 0..<40 {
            let ready = try await evaluate(webView, "Boolean(window.__AIWhaleSettings && document.querySelector('#nav button'))")
            if (ready as? Bool) == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let pages = try await evaluate(webView, """
          (function () {
            var ids = ['general','accounts','bubbles','appearance','sounds','alerts','about']
            var present = {}
            ids.forEach(function (id) {
              present[id] = Boolean(document.querySelector('.page[data-page=\"' + id + '\"]') && document.querySelector('#nav button[data-page=\"' + id + '\"]'))
            })
            return present
          }())
        """) as? [String: Any] ?? [:]
        for id in ["general", "accounts", "bubbles", "appearance", "sounds", "alerts", "about"] {
            XCTAssertEqual(pages[id] as? Bool, true, "missing settings page \(id)")
        }

        _ = try await evaluate(webView, "document.querySelector(\"#nav button[data-page='bubbles']\").click()")
        try await Task.sleep(nanoseconds: 80_000_000)
        let bubbles = try await evaluate(webView, """
          ({
            preview: Boolean(document.querySelector('.dshwv-bubpvbox, .dshwv-minipop')),
            iframe: Boolean(document.querySelector('iframe')),
            mount: Boolean(document.querySelector('#upstreamEditorMount')),
            editor: Boolean(window.__AIWhaleEditorAPI && window.__AIWhaleEditorAPI.openBubbleEditor),
            editorVisible: Boolean(document.querySelector('#upstreamEditorMount .dshwv-bubmask[style*="flex"]')),
            queueRows: document.querySelectorAll('#upstreamEditorMount .dshwv-bubrow').length
          })
        """) as? [String: Any] ?? [:]
        XCTAssertEqual(bubbles["preview"] as? Bool, true, "the real upstream preview must be mounted")
        XCTAssertEqual(bubbles["iframe"] as? Bool, false)
        XCTAssertEqual(bubbles["mount"] as? Bool, true)
        XCTAssertEqual(bubbles["editor"] as? Bool, true)
        XCTAssertEqual(bubbles["editorVisible"] as? Bool, true)
        XCTAssertGreaterThan(bubbles["queueRows"] as? Int ?? 0, 0)

        _ = try await evaluate(webView, "document.querySelector(\"#nav button[data-page='accounts']\").click()")
        try await Task.sleep(nanoseconds: 80_000_000)
        let accounts = try await evaluate(webView, "Boolean(document.querySelector('[data-acc], #accountCards') && document.body.innerText.indexOf('Codex') >= 0)")
        XCTAssertEqual(accounts as? Bool, true)

        let codexConnection = try await evaluate(webView, "({path:document.querySelector('[data-acc=codex] #codexPath').value, home:document.querySelector('[data-acc=codex] #codexHome').value, tokenInput:Boolean(document.querySelector('[data-acc=codex] textarea'))})") as? [String: Any] ?? [:]
        XCTAssertEqual(codexConnection["path"] as? String, "/opt/homebrew/bin/codex")
        XCTAssertEqual(codexConnection["home"] as? String, "/Users/test/.codex")
        XCTAssertEqual(codexConnection["tokenInput"] as? Bool, false, "Codex must use the browser/CLI login flow rather than a pasted credential")
        _ = try await evaluate(webView, "document.querySelector('[data-acc=codex] #loginCodex').click()")
        for _ in 0..<20 {
            if bridge.receivedTypes.contains("loginCodex") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(bridge.receivedTypes.contains("loginCodex"), "browser login must cross the native bridge")
    }

    func testPackagedWidgetContinuousNativePointerQueueDoesNotAccumulate() async throws {
        let resourceRoot = try makeResourceRoot()
        let html = resourceRoot.appendingPathComponent("WhaleWidget.html")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 420), configuration: WKWebViewConfiguration())
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        let loaded = expectation(description: "continuous widget loaded")
        delegate.onFinish = { loaded.fulfill() }
        delegate.onFailure = { error in XCTFail("continuous widget failed: \(error)"); loaded.fulfill() }
        webView.loadFileURL(html, allowingReadAccessTo: resourceRoot)
        await fulfillment(of: [loaded], timeout: 10)
        try await waitForJavaScript(webView)
        _ = try await evaluate(webView, """
          window.__AIWhale.update({
            accounts:[{id:'codex',name:'Codex',provider:'codex',kind:'subscription',enabled:true,status:'ok',windows:[{id:'5h',label:'5 小时',remainPct:62,usedPct:38}]}],
            bubble:{steps:[
              {id:'a',modules:[{type:'text',text:'A'},{type:'quota',accountId:'codex',windowId:'5h'}]},
              {id:'b',modules:[{type:'text',text:'B'},{type:'quota',accountId:'codex',windowId:'5h'}]},
              {id:'c',modules:[{type:'text',text:'C'},{type:'quota',accountId:'codex',windowId:'5h'}]}
            ],advanceOnClick:true},
            bubbleSteps:[
              {id:'a',modules:[{type:'text',text:'A'},{type:'quota',accountId:'codex',windowId:'5h'}]},
              {id:'b',modules:[{type:'text',text:'B'},{type:'quota',accountId:'codex',windowId:'5h'}]},
              {id:'c',modules:[{type:'text',text:'C'},{type:'quota',accountId:'codex',windowId:'5h'}]}
            ],bubbleRevision:'continuous-queue'
          })
        """)
        _ = try await evaluate(webView, """
          (function () {
            for (var i=0;i<50;i++) {
              window.__AIWhale.nativePointerDown();
              window.__AIWhale.nativePointerUp(false);
              if (i % 5 === 0) window.__AIWhale.update({accounts:[{id:'codex',name:'Codex',provider:'codex',kind:'subscription',enabled:true,status:'ok',windows:[{id:'5h',label:'5 小时',remainPct:62 - (i % 10),usedPct:38 + (i % 10)}]}]});
            }
            return true;
          }())
        """)
        try await Task.sleep(nanoseconds: 700_000_000)
        let result = try await evaluate(webView, """
          (function () {
            var box = document.querySelector('.dshwv-text');
            var nodes = box ? box.querySelectorAll('.dshwv-trow,.dshwv-mimg,.dshwv-nowdex,.dshwv-module').length : 0;
            return {visible:Boolean(document.querySelector('.dshwv-pop-open')), nodes:nodes, text:(box && box.innerText || '').replace(/\\s+/g,' ').trim()};
          }())
        """) as? [String: Any] ?? [:]
        XCTAssertEqual(result["visible"] as? Bool, true, "the fiftieth native click must still leave the active queue responsive")
        XCTAssertLessThanOrEqual(result["nodes"] as? Int ?? 999, 4, "dynamic module nodes must be replaced, not accumulated")
        XCTAssertTrue(["A", "B", "C"].contains(result["text"] as? String ?? ""), "only the current queue item may remain")
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
        _ = try await evaluate(webView, """
          window.__AIWhale.update({
            showMenuButton: true,
            accounts: [
              {id:'codex',name:'Codex',provider:'codex',kind:'subscription',enabled:true,windows:[{id:'5h',label:'5 小时',remainPct:62,usedPct:38,resetAt:null}]},
              {id:'deepseek',name:'DeepSeek',provider:'deepseek',kind:'balance',enabled:true,remaining:42.18,currency:'CNY'}
            ],
            bubble: {steps: [
              {id:'step-dash',modules:[{type:'dashboard'}]},
              {id:'step-codex',modules:[{type:'text',text:'Codex 订阅',size:12,bold:true},{type:'quota',accountId:'codex',windowId:'5h',field:'full'}]}
            ], advanceOnClick: true},
            bubbleSteps: [
              {id:'step-dash',modules:[{type:'dashboard'}]},
              {id:'step-codex',modules:[{type:'text',text:'Codex 订阅',size:12,bold:true},{type:'quota',accountId:'codex',windowId:'5h',field:'full'}]}
            ],
            bubbleRevision: 'test-queue-2'
          })
        """)

        for scale in [0.65, 1.0, 1.6] {
            _ = try await evaluate(webView, "window.__AIWhale.setLayout({scale:\(scale), height:\(184 * scale)})")
            try await Task.sleep(nanoseconds: 80_000_000)
            let metrics = try await widgetMetrics(webView)
            assertVisible(metrics, expectedHeight: 184 * scale, label: "compact scale \(scale)")
            print("WHALE_WEBKIT_GEOMETRY compact scale=\(scale) app=\(rect(metrics, "app")) whale=\(rect(metrics, "whale")) computedHeight=\(metrics["computedHeight"] ?? "?")")
        }

        _ = try await evaluate(webView, "window.__AIWhale.setLayout({scale:1.0, height:184})")
        try await Task.sleep(nanoseconds: 100_000_000)
        // Exercise the same bridge methods called by WhaleWindowController after
        // a real native mouse down/up pair. This must not call toggleBubble()
        // directly, otherwise a passing test could bypass the input bridge.
        _ = try await evaluate(webView, "window.__AIWhale.nativePointerDown()")
        _ = try await evaluate(webView, "window.__AIWhale.nativePointerUp(false)")
        try await Task.sleep(nanoseconds: 180_000_000)
        let expanded = try await widgetMetrics(webView)
        assertVisible(expanded, expectedHeight: 184, label: "expanded bubble")
        XCTAssertEqual(expanded["bubbleVisible"] as? Bool, true)
        XCTAssertGreaterThan(rectValue(expanded, "bubble", "height"), 0)
        XCTAssertTrue((expanded["bubbleText"] as? String ?? "").contains("额度总览"), "settings dashboard step must render on the click bubble")
        XCTAssertEqual(expanded["menuHidden"] as? Bool, false)
        XCTAssertEqual(expanded["menuPinned"] as? Bool, true)
        print("WHALE_WEBKIT_GEOMETRY expanded app=\(rect(expanded, "app")) whale=\(rect(expanded, "whale")) bubble=\(rect(expanded, "bubble"))")

        // A completed drag must not be converted into a second click.
        _ = try await evaluate(webView, "window.__AIWhale.nativePointerDown()")
        _ = try await evaluate(webView, "window.__AIWhale.nativePointerUp(true)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterDrag = try await widgetMetrics(webView)
        XCTAssertEqual(afterDrag["bubbleVisible"] as? Bool, true)

        _ = try await evaluate(webView, "window.__AIWhale.nativePointerDown()")
        _ = try await evaluate(webView, "window.__AIWhale.nativePointerUp(false)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let collapsed = try await widgetMetrics(webView)
        assertVisible(collapsed, expectedHeight: 184, label: "collapsed bubble")
        // The native click path follows the upstream again-click queue. It may
        // advance to the next bubble instead of forcibly hiding the current one.
        XCTAssertEqual(collapsed["bubbleVisible"] as? Bool, true)
        print("WHALE_WEBKIT_GEOMETRY collapsed app=\(rect(collapsed, "app")) whale=\(rect(collapsed, "whale"))")

        _ = try await evaluate(webView, """
          window.__AIWhale.update({
            showMenuButton: true,
            accounts: [{id:'codex',name:'Codex',provider:'codex',kind:'subscription',enabled:true,windows:[{id:'5h',label:'5 小时',remainPct:62,usedPct:38}]}],
            bubble: {steps: [
              {id:'step-edit',modules:[{type:'text',text:'设置页改过的气泡',size:14,bold:true}]},
              {id:'step-keep',modules:[{type:'text',text:'第二步',size:12}]}
            ], advanceOnClick: true},
            bubbleSteps: [
              {id:'step-edit',modules:[{type:'text',text:'设置页改过的气泡',size:14,bold:true}]},
              {id:'step-keep',modules:[{type:'text',text:'第二步',size:12}]}
            ],
            bubbleRevision: 'test-settings-sync'
          })
        """)
        try await Task.sleep(nanoseconds: 180_000_000)
        let synced = try await widgetMetrics(webView)
        XCTAssertEqual(synced["bubbleVisible"] as? Bool, true)
        XCTAssertTrue((synced["bubbleText"] as? String ?? "").contains("设置页改过的气泡"), "settings bubble edits must appear on the click bubble")

        _ = try await evaluate(webView, "document.querySelector(\".dshwv-img\").src = \"missing-custom-role.png\"")
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
          var app = document.querySelector('.dshwv-root');
          var whale = document.querySelector('.dshwv-img');
          var bubble = document.querySelector('.dshwv-pop');
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
          var menu = document.querySelector('.dshwv-menu-btn');
          return {
            computedHeight: getComputedStyle(app).height,
            app: rect(app),
            whale: rect(whale),
            bubble: rect(bubble),
            bubbleVisible: bubble.classList.contains('dshwv-pop-open'),
            bubbleText: (bubble.innerText || bubble.textContent || '').replace(/\\s+/g, ' ').trim(),
            menuHidden: !!(menu && menu.classList.contains('dshwv-menu-btn-hidden')),
            menuPinned: !!(menu && menu.classList.contains('dshwv-menu-btn-pinned')),
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
            let ready = try await evaluate(webView, "Boolean(document.querySelector('.dshwv-img'))")
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
        try fileManager.copyItem(at: packageRoot.appendingPathComponent("Resources/Settings.html"), to: tempRoot.appendingPathComponent("Settings.html"))
        for name in ["DSniang1.png", "Ya1.mp3", "Ya2.mp3", "whale-widget.js", "rua.gif", "bubble-petpet.gif"] {
            let source = sourceRoot.appendingPathComponent("assets").appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: tempRoot.appendingPathComponent(name))
            }
        }
        return tempRoot
    }
}
