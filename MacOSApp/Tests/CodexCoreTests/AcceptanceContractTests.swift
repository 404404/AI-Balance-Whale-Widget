import Foundation
import XCTest
@testable import CodexCore

final class BindingModelTests: XCTestCase {
    func testLegacyModelIDMigrationIsIdempotentAndLossless() {
        let legacy: [String: Any] = ["type": "quota", "modelId": "codex", "windowId": "primary-300", "tpl": "剩余 {remain}", "size": 8]
        let first = AccountMetricBinding.migrateModule(legacy)
        let second = AccountMetricBinding.migrateModule(first)
        XCTAssertEqual(first["accountId"] as? String, "codex")
        XCTAssertEqual(first["windowId"] as? String, "primary-300")
        XCTAssertEqual(first["tpl"] as? String, "剩余 {remain}")
        XCTAssertNil(first["modelId"])
        XCTAssertEqual(second["accountId"] as? String, first["accountId"] as? String)
        XCTAssertEqual(second["tpl"] as? String, first["tpl"] as? String)
    }

    func testMoneyAndSubscriptionMetricsKeepUnitsAndUnknowns() {
        XCTAssertEqual(AccountMetricBinding.finiteMetric(42.18, kind: .balance), 42.18)
        XCTAssertEqual(AccountMetricBinding.finiteMetric(62, kind: .subscription), 62)
        XCTAssertNil(AccountMetricBinding.finiteMetric(101, kind: .subscription))
        XCTAssertNil(AccountMetricBinding.finiteMetric(true, kind: .subscription))
        XCTAssertNil(AccountMetricBinding.finiteMetric("", kind: .balance))
    }
}

final class BubbleStateTests: XCTestCase {
    func testDataRefreshPreservesStepChoiceAndDeadline() {
        let deadline = Date(timeIntervalSince1970: 1_900_000_000)
        let before = BubbleSceneSnapshot(stepID: "choice-2", choiceID: "random-line-17", deadline: deadline)
        let after = before.afterDataRefresh()
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.stepID, "choice-2")
        XCTAssertEqual(after.choiceID, "random-line-17")
        XCTAssertEqual(after.deadline, deadline)
        XCTAssertTrue(after.visible)
    }
}

final class BrowserAuthAcceptanceTests: XCTestCase {
    private func request() -> CodexOAuthRequest { CodexOAuthSupport.makeRequest(port: 41723, random: { Data(repeating: 7, count: 32) }) }

    func testCodexLoginAndQuotaWithoutCLIOrCodexHome() throws {
        let req = request()
        let url = try XCTUnwrap(CodexOAuthSupport.authorizationURL(request: req))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(query.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertEqual(query.first(where: { $0.name == "redirect_uri" })?.value, req.redirectURI)
        XCTAssertNil(query.first(where: { $0.name == "codex_path" }))
        XCTAssertNil(query.first(where: { $0.name == "CODEX_HOME" }))
        let usage = try String(contentsOf: repository().appendingPathComponent("MacOSApp/Sources/AIBalanceWhale/CodexHTTPUsageClient.swift"))
        XCTAssertTrue(usage.contains("chatgpt.com/backend-api/wham/usage"))
        XCTAssertTrue(usage.contains("CodexCredentialStore"))
    }

    func testCodexOAuthUsesRegisteredLoopbackCallbackPorts() throws {
        XCTAssertEqual(CodexOAuthSupport.registeredCallbackPorts, [1455, 1457])
        for port in CodexOAuthSupport.registeredCallbackPorts {
            let request = CodexOAuthSupport.makeRequest(port: port, random: { Data(repeating: 9, count: 32) })
            let url = try XCTUnwrap(CodexOAuthSupport.authorizationURL(request: request))
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
            XCTAssertEqual(redirect, "http://localhost:" + String(port) + "/auth/callback")
        }
        let coordinator = try String(contentsOf: repository().appendingPathComponent("MacOSApp/Sources/AIBalanceWhale/CodexOAuthCoordinator.swift"))
        XCTAssertTrue(coordinator.contains("registeredCallbackPorts"))
        XCTAssertFalse(coordinator.contains("port: 0"), "OAuth must not advertise an ephemeral callback port")
    }

    func testCallbacksRejectMismatchReplayAndLateCompletion() throws {
        let req = request()
        let valid = URL(string: "http://localhost:41723/auth/callback?code=one&state=\(req.state)")!
        guard case .success(let callback) = CodexOAuthSupport.validateCallback(valid, request: req) else { return XCTFail("valid callback rejected") }
        XCTAssertEqual(callback.code, "one")
        let wrongState = URL(string: "http://localhost:41723/auth/callback?code=two&state=wrong")!
        if case .success = CodexOAuthSupport.validateCallback(wrongState, request: req) { XCTFail("state mismatch accepted") }
        let wrongPath = URL(string: "http://localhost:41723/other?code=two&state=\(req.state)")!
        if case .success = CodexOAuthSupport.validateCallback(wrongPath, request: req) { XCTFail("late/wrong callback accepted") }
        let denied = URL(string: "http://localhost:41723/auth/callback?error=access_denied&state=\(req.state)")!
        if case .success = CodexOAuthSupport.validateCallback(denied, request: req) { XCTFail("provider denial accepted as login") }
    }

    func testRefreshAndDisconnectUseIsolatedNativeCredentials() throws {
        let source = try String(contentsOf: repository().appendingPathComponent("MacOSApp/Sources/AIBalanceWhale/CodexCredentialStore.swift"))
        XCTAssertTrue(source.contains("com.404404.AIBalanceWhale.codex-auth"))
        XCTAssertTrue(source.contains("SecItemDelete"))
        XCTAssertFalse(source.contains("UserDefaults.standard.set(credential.accessToken"))
        XCTAssertTrue(source.contains("refreshWaiters"), "refreshes must be single-flight")
    }

    func testProviderCapabilityFlowsAndQuotaScopeFailures() throws {
        let req = request()
        let url = try XCTUnwrap(CodexOAuthSupport.authorizationURL(request: req))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "scope" })?.value, CodexOAuthSupport.scope)
        let parser = WhamUsageParser.parse(["rate_limit": ["primary_window": ["used_percent": 100, "limit_window_seconds": 60, "reset_at": 1_900_000_000]], "additional_rate_limits": [["metered_feature": "extra", "rate_limit": NSNull()]]])
        XCTAssertEqual(parser.buckets.count, 1)
        XCTAssertEqual(parser.buckets.first?.remainingPercent, 0)
        XCTAssertNil(WhamUsageParser.parse(["html": "login"]).buckets.first)
    }

    func testSettingsShowsOneAuthFlowPerAccountAndNoCodexPaths() throws {
        let html = try String(contentsOf: repository().appendingPathComponent("MacOSApp/Resources/Settings.html"))
        XCTAssertTrue(html.contains("loginCodex"))
        XCTAssertTrue(html.contains("refreshCodex"))
        XCTAssertTrue(html.contains("disconnectCodex"))
        XCTAssertFalse(html.contains("id=\"codexPath\""))
        XCTAssertFalse(html.contains("id=\"codexHome\""))
        XCTAssertFalse(html.contains("sessionToken"))
    }

    private func repository() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
