import XCTest
@testable import CodexCore

final class RateLimitModelsTests: XCTestCase {
    func testSingleBucketAndNullSecondary() {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_730_000_000],
                "secondary": NSNull(),
            ],
        ]
        let parsed = RateLimitParser.parse(result)
        XCTAssertEqual(parsed.buckets.count, 1)
        XCTAssertEqual(parsed.buckets[0].remainingPercent, 75)
        XCTAssertEqual(parsed.buckets[0].window, .primary)
    }

    func testMultiBucketViewAvoidsLegacyDuplicate() {
        let result: [String: Any] = [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 1]],
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 20, "windowDurationMins": 15]],
                "weekly": ["limitName": "团队周额度", "secondary": ["usedPercent": 100, "windowDurationMins": 10080]],
            ],
        ]
        let parsed = RateLimitParser.parse(result)
        XCTAssertEqual(parsed.buckets.count, 2)
        XCTAssertEqual(parsed.buckets.first(where: { $0.id == "weekly" })?.remainingPercent, 0)
    }

    func testInvalidPercentNeverBecomesZeroOrOneHundred() {
        let parsed = RateLimitParser.parse([
            "rateLimits": ["primary": ["usedPercent": 101, "resetsAt": "not-a-time"], "secondary": ["usedPercent": NSNull()]],
        ])
        XCTAssertEqual(parsed.buckets.count, 2)
        XCTAssertNil(parsed.buckets[0].usedPercent)
        XCTAssertNil(parsed.buckets[0].remainingPercent)
        XCTAssertNil(parsed.buckets[1].remainingPercent)
        XCTAssertNil(parsed.buckets[0].resetsAt)
    }

    func testNotificationPayloadAndDynamicWindowNames() {
        let parsed = RateLimitParser.parse([
            "method": "account/rateLimits/updated",
            "params": ["rateLimits": ["primary": ["usedPercent": 50, "windowDurationMins": 1440]]],
        ])
        let bucket = try! XCTUnwrap(parsed.buckets.first)
        XCTAssertEqual(RateLimitPresentation.windowName(for: bucket, durationMinutes: 1440), "1天窗口")
        XCTAssertEqual(RateLimitPresentation.windowName(for: bucket, durationMinutes: 10080), "每周窗口")
        XCTAssertEqual(RateLimitPresentation.windowName(for: bucket, durationMinutes: 17), "17分钟窗口")
    }
}
