import Foundation

public enum AccountMetricKind: String, Codable, Sendable {
    case balance
    case subscription
}

public struct AccountMetricBinding: Codable, Equatable, Sendable {
    public var accountID: String
    public var metric: String
    public var windowID: String?
    public var template: String?

    public init(accountID: String, metric: String, windowID: String? = nil, template: String? = nil) {
        self.accountID = accountID
        self.metric = metric
        self.windowID = windowID
        self.template = template
    }

    /// Converts the beta modelId field without dropping unrelated module keys.
    public static func migrateModule(_ raw: [String: Any]) -> [String: Any] {
        var next = raw
        if next["accountId"] == nil, let legacy = raw["modelId"] as? String, !legacy.isEmpty { next["accountId"] = legacy }
        if next["metric"] == nil { next["metric"] = raw["type"] as? String == "balance" ? "balance" : "remaining" }
        next.removeValue(forKey: "modelId")
        return next
    }

    public static func finiteMetric(_ value: Any?, kind: AccountMetricKind) -> Double? {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c" else { return nil }
        let result = n.doubleValue
        guard result.isFinite else { return nil }
        if kind == .subscription, !(0...100).contains(result) { return nil }
        return result
    }
}

public struct BubbleSceneSnapshot: Equatable, Sendable {
    public var stepID: String
    public var choiceID: String?
    public var deadline: Date?
    public var visible: Bool

    public init(stepID: String, choiceID: String?, deadline: Date?, visible: Bool = true) {
        self.stepID = stepID
        self.choiceID = choiceID
        self.deadline = deadline
        self.visible = visible
    }

    public func afterDataRefresh() -> BubbleSceneSnapshot {
        self
    }
}
