import XCTest
@testable import CodexCore

final class AccountCatalogTests: XCTestCase {
    func testDefaultAccountsAreParallelNotExclusive() {
        let accounts = AccountCatalog.defaultAccounts()
        XCTAssertEqual(accounts.map { $0["id"] as? String }, ["codex", "grok", "cursor", "deepseek"])
        XCTAssertEqual(accounts.map { $0["kind"] as? String }, ["subscription", "subscription", "subscription", "balance"])
        XCTAssertTrue(accounts.allSatisfy { ($0["enabled"] as? Bool) == true })
        XCTAssertTrue(accounts.allSatisfy { ($0["authMode"] as? String) == "demo" })
        XCTAssertTrue(accounts.allSatisfy { ($0["status"] as? String) == "demo" })
        XCTAssertTrue(accounts.allSatisfy { ($0["windows"] as? [[String: Any]] ?? []).isEmpty })
        XCTAssertNil(accounts.first?["remaining"])
        XCTAssertNil(accounts.first?["token"])
    }

    func testDefaultBubbleQueueStartsWithDashboardThenProviders() {
        let steps = AccountCatalog.defaultBubbleSteps()
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual((steps[0]["modules"] as? [[String: Any]])?.first?["type"] as? String, "dashboard")
        XCTAssertEqual((steps[1]["modules"] as? [[String: Any]])?[1]["accountId"] as? String, "codex")
        XCTAssertEqual((steps[4]["modules"] as? [[String: Any]])?[1]["type"] as? String, "balance")
        XCTAssertEqual((steps[5]["modules"] as? [[String: Any]])?[0]["type"] as? String, "random")
    }

    func testRandomDefaultsContainUpstreamFullPool() {
        XCTAssertEqual(AccountCatalog.randomLines.count, 48)
        XCTAssertTrue(AccountCatalog.randomLines.contains("你知道吗？我删过作者的库哦..."))
    }

    func testUpstreamFixtureMatchesBundledRendererSnapshot() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent() // CodexCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MacOSApp
            .deletingLastPathComponent() // repository
        let fixtureURL = repository.appendingPathComponent("MacOSApp/acceptance/upstream-bubble-defaults.json")
        let assetURL = repository.appendingPathComponent("assets/whale-widget.js")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
        let asset = try String(contentsOf: assetURL, encoding: .utf8)
        let marker = "var BUBBLE_DEFAULT_ITEMS = "
        let start = try XCTUnwrap(asset.range(of: marker)).upperBound
        let closing = try XCTUnwrap(asset.range(of: "\n];", range: start..<asset.endIndex))
        let jsonEnd = asset.index(before: closing.upperBound) // include ] but exclude the JavaScript semicolon
        let snapshot = try JSONSerialization.jsonObject(with: Data(asset[start..<jsonEnd].utf8))
        let normalizedFixture = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let normalizedSnapshot = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        XCTAssertEqual(normalizedFixture, normalizedSnapshot, "the editor/default queue fixture must match the upstream renderer snapshot")
    }

    func testMigrationSeedsCoreAccountsAndCanonicalSteps() {
        let migrated = AccountCatalog.migrate([
            "schemaVersion": 3,
            "providerMode": "codex",
            "providers": [["id": "deepseek", "name": "DeepSeek", "enabled": true, "keyRef": "DEEPSEEK_API_KEY"]],
            "bubble": ["steps": [["kind": "status", "text": "Codex 订阅额度"]]],
            "appearance": [:],
        ])
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 4)
        XCTAssertNil(migrated["providerMode"])
        let accounts = migrated["accounts"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(accounts.compactMap { $0["id"] as? String }).isSuperset(of: AccountCatalog.coreAccountIDs), true)
        let deepseek = accounts.first { ($0["id"] as? String) == "deepseek" }
        XCTAssertEqual(deepseek?["keyRef"] as? String, "DEEPSEEK_API_KEY")
        let steps = (migrated["bubble"] as? [String: Any])?["steps"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 6)
        XCTAssertEqual((migrated["appearance"] as? [String: Any])?["showMenuButton"] as? Bool, true)
    }

    func testStripSecretNeverPersistsToken() {
        let stripped = AccountCatalog.stripSecret(["id": "grok", "token": "secret-value", "provider": "grok"])
        XCTAssertEqual(stripped["token"] as? String, "")
        XCTAssertEqual(stripped["keyRef"] as? String, "account.grok")
    }

    func testCodexLiveFetchesWithoutPastedToken() {
        XCTAssertTrue(AccountCatalog.shouldLiveFetch(provider: "codex", authMode: "demo", hasToken: false))
        XCTAssertFalse(AccountCatalog.shouldLiveFetch(provider: "grok", authMode: "demo", hasToken: false))
        XCTAssertTrue(AccountCatalog.shouldLiveFetch(provider: "grok", authMode: "token", hasToken: true))
        XCTAssertFalse(AccountCatalog.shouldLiveFetch(provider: "deepseek", authMode: "token", hasToken: false))
        XCTAssertTrue(AccountCatalog.shouldLiveFetch(provider: "cursor", authMode: "token", hasToken: true))
    }

    func testBubbleRevisionChangesWhenSettingsOrQuotaChange() {
        let steps = AccountCatalog.defaultBubbleSteps()
        let accounts = AccountCatalog.defaultAccounts()
        let first = AccountCatalog.bubbleRevision(steps: steps, accounts: accounts)
        var edited = steps
        edited[0] = ["id": "step-dash", "modules": [["type": "text", "text": "改过的气泡"]]]
        XCTAssertNotEqual(first, AccountCatalog.bubbleRevision(steps: edited, accounts: accounts))
        var refreshed = accounts
        var codex = refreshed[0]
        codex["windows"] = [["id": "5h", "label": "5 小时", "remainPct": 10, "usedPct": 90]]
        refreshed[0] = codex
        XCTAssertNotEqual(first, AccountCatalog.bubbleRevision(steps: steps, accounts: refreshed))
    }

    func testCodexBucketsMapToFiveHourAndWeekWindows() {
        let buckets = [
            RateLimitBucket(id: "codex", name: nil, window: .primary, windowDurationMinutes: 300, usedPercent: 38, resetsAt: Date(timeIntervalSince1970: 1_730_000_000)),
            RateLimitBucket(id: "codex", name: nil, window: .secondary, windowDurationMinutes: 10080, usedPercent: 19, resetsAt: Date(timeIntervalSince1970: 1_730_100_000)),
        ]
        let windows = AccountCatalog.windows(from: buckets)
        XCTAssertEqual(windows.map(\.id), ["primary-300", "secondary-10080"])
        XCTAssertEqual(windows[0].remainPct, 62)
        XCTAssertEqual(windows[1].remainPct, 81)
    }
}

final class QuotaJSONParserTests: XCTestCase {
    func testDeepSeekBalancePath() throws {
        let result = QuotaJSONParser.parseDeepSeek([
            "balance_infos": [["total_balance": "42.18", "currency": "CNY"]],
        ])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.remaining, 42.18)
    }

    func testOpenRouterRemainingIsTotalMinusUsed() {
        let result = QuotaJSONParser.parseOpenRouter(["data": ["total_credits": 10, "total_usage": 2.5]])
        XCTAssertEqual(result.remaining, 7.5)
        XCTAssertEqual(result.used, 2.5)
        XCTAssertEqual(result.total, 10)
    }

    func testGrokWeeklyPercent() {
        let result = QuotaJSONParser.parseGrok(["used_percent": 56, "reset_at": 1_730_000_000])
        XCTAssertEqual(result.windows.first?.id, "week")
        XCTAssertEqual(result.windows.first?.remainPct, 44)
    }

    func testCursorPlanUsageWindows() {
        let result = QuotaJSONParser.parseCursor([
            "planUsage": ["autoPercentUsed": 0.29, "apiPercentUsed": 62, "botPercentUsed": 10],
        ])
        XCTAssertEqual(result.windows.map(\.id), ["cursor", "other", "bot"])
        XCTAssertEqual(result.windows[0].remainPct, 71, accuracy: 0.01)
        XCTAssertEqual(result.windows[1].remainPct, 38, accuracy: 0.01)
    }

    func testParseFailureDoesNotInventWindows() {
        XCTAssertFalse(QuotaJSONParser.parseDeepSeek(["oops": true]).ok)
        XCTAssertTrue(QuotaJSONParser.parseCursor(["planUsage": [:]]).windows.isEmpty)
        XCTAssertFalse(QuotaJSONParser.parse(provider: "unknown", object: [:]).ok)
    }
}
