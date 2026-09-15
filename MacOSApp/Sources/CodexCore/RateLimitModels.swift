import Foundation

public struct RateLimitBucket: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let window: Window
    public let windowDurationMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?

    public enum Window: String, Codable, Sendable {
        case primary
        case secondary
    }

    public init(id: String, name: String?, window: Window, windowDurationMinutes: Int?, usedPercent: Double?, resetsAt: Date?) {
        self.id = id
        self.name = name
        self.window = window
        self.windowDurationMinutes = windowDurationMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return 100 - usedPercent
    }

    public var windowName: String {
        guard let name, !name.isEmpty else { return window == .primary ? "主额度" : "次额度" }
        return name
    }
}

public struct ParsedRateLimits: Codable, Equatable, Sendable {
    public let buckets: [RateLimitBucket]
    public let planType: String?
    public let parsedAt: Date

    public init(buckets: [RateLimitBucket], planType: String?, parsedAt: Date) {
        self.buckets = buckets
        self.planType = planType
        self.parsedAt = parsedAt
    }
}

public enum RateLimitParser {
    /// Parses the result object returned by account/rateLimits/read or the payload
    /// of account/rateLimits/updated. Unknown fields are intentionally ignored.
    public static func parse(_ object: [String: Any], now: Date = Date()) -> ParsedRateLimits {
        let payload: [String: Any]
        if let result = object["result"] as? [String: Any] {
            payload = result
        } else if let params = object["params"] as? [String: Any] {
            payload = params
        } else {
            payload = object
        }

        var source: [[String: Any]] = []
        if let byID = payload["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            for (key, value) in byID {
                guard var bucket = value as? [String: Any] else { continue }
                if bucket["limitId"] == nil { bucket["limitId"] = key }
                source.append(bucket)
            }
        } else if let single = payload["rateLimits"] as? [String: Any] {
            source = [single]
        }

        var buckets: [RateLimitBucket] = []
        for item in source {
            let id = string(item["limitId"]) ?? string(item["id"]) ?? "codex"
            let name = string(item["limitName"]) ?? string(item["name"])
            appendWindow(from: item["primary"], id: id, name: name, window: .primary, into: &buckets)
            appendWindow(from: item["secondary"], id: id, name: name, window: .secondary, into: &buckets)
        }

        // A few CLI versions have returned the same limit under an alias. Keep one
        // row for an identical bucket rather than double-counting it in the UI.
        var seen = Set<String>()
        buckets = buckets.filter { bucket in
            let reset = bucket.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
            let key = "\(bucket.id)|\(bucket.window.rawValue)|\(bucket.usedPercent.map(String.init) ?? "invalid")|\(reset)"
            return seen.insert(key).inserted
        }

        return ParsedRateLimits(
            buckets: buckets.sorted { lhs, rhs in
                if lhs.id != rhs.id { return lhs.id < rhs.id }
                return lhs.window.rawValue < rhs.window.rawValue
            },
            planType: string(payload["planType"]),
            parsedAt: now
        )
    }

    private static func appendWindow(
        from value: Any?,
        id: String,
        name: String?,
        window: RateLimitBucket.Window,
        into buckets: inout [RateLimitBucket]
    ) {
        guard let value = value as? [String: Any] else { return }
        let rawPercent = number(value["usedPercent"])
        let used = rawPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let duration = number(value["windowDurationMins"]).flatMap { value in
            guard value.isFinite, value > 0, value <= Double(Int.max) else { return nil }
            return Int(value)
        }
        let resetSeconds = number(value["resetsAt"])
        // The protocol defines resetsAt as Unix seconds. Values outside a sane
        // seconds range are treated as unknown, never silently interpreted as ms.
        let reset = resetSeconds.flatMap { seconds -> Date? in
            guard seconds.isFinite, seconds > 0, seconds < 4_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        buckets.append(RateLimitBucket(id: id, name: name, window: window, windowDurationMinutes: duration, usedPercent: used, resetsAt: reset))
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public enum RateLimitPresentation {
    public static func windowName(for bucket: RateLimitBucket, durationMinutes: Int?) -> String {
        guard let durationMinutes, durationMinutes > 0 else {
            return bucket.window == .primary ? "主额度窗口" : "次额度窗口"
        }
        if durationMinutes % (7 * 24 * 60) == 0 { return "每周窗口" }
        if durationMinutes % (24 * 60) == 0 { return "\(durationMinutes / (24 * 60))天窗口" }
        if durationMinutes % 60 == 0 { return "\(durationMinutes / 60)小时窗口" }
        return "\(durationMinutes)分钟窗口"
    }
}
