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

    func testLayoutScalesWithoutMovingBottomAnchor() {
        let compact = WidgetLayoutModel.contentSize(scale: 1, bubbleVisible: false, bubbleHeight: 178)
        let small = WidgetLayoutModel.contentSize(scale: 0.65, bubbleVisible: false, bubbleHeight: 178)
        let large = WidgetLayoutModel.contentSize(scale: 1.6, bubbleVisible: false, bubbleHeight: 178)
        XCTAssertEqual(compact.width, 248)
        XCTAssertEqual(compact.height, 184)
        XCTAssertEqual(small.height, 184 * 0.65, accuracy: 0.001)
        XCTAssertEqual(large.height, 184 * 1.6, accuracy: 0.001)
        XCTAssertEqual(WidgetLayoutModel.preservedBottomOrigin(oldMinY: 100, oldHeight: 274, newHeight: 184), 190)
    }

    func testBubbleExpansionIsCalculatedFromMeasuredHeight() {
        let hidden = WidgetLayoutModel.contentSize(scale: 1, bubbleVisible: false, bubbleHeight: 166)
        let shown = WidgetLayoutModel.contentSize(scale: 1, bubbleVisible: true, bubbleHeight: 166)
        XCTAssertGreaterThan(shown.height, hidden.height)
        XCTAssertEqual(shown.height, 346)
        XCTAssertEqual(WidgetLayoutModel.contentSize(scale: 1, bubbleVisible: true, bubbleHeight: 100).height, 300)
    }

    func testBubbleQueueClickAndDragContract() {
        var queue = BubbleQueueModel(count: 3, advanceOnClick: true)
        queue.clickWhale()
        XCTAssertTrue(queue.visible)
        XCTAssertEqual(queue.index, 0)
        queue.clickWhale()
        XCTAssertTrue(queue.visible)
        XCTAssertEqual(queue.index, 1)
        queue.clickWhale()
        XCTAssertTrue(queue.visible)
        XCTAssertEqual(queue.index, 2)
        queue.clickWhale()
        XCTAssertFalse(queue.visible)
        XCTAssertEqual(queue.index, 0)
    }

    func testBubbleAgainToggleDoesNotAdvanceWhenAdvanceDisabled() {
        var queue = BubbleQueueModel(count: 3, advanceOnClick: false, againAction: "toggle")
        queue.clickWhale()
        queue.clickWhale()
        XCTAssertFalse(queue.visible)
        XCTAssertEqual(queue.index, 0)
    }
}
