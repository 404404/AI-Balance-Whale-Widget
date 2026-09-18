import Foundation

/// Adapter for the read-only ChatGPT WHAM usage response used by the official
/// Codex client. This deliberately stays separate from the app-server parser:
/// WHAM uses snake_case fields and seconds, while app-server uses camelCase
/// fields and minutes.
public enum WhamUsageParser {
    public static func parse(_ object: [String: Any], now: Date = Date()) -> ParsedRateLimits {
        let plan = string(object["plan_type"])
        var buckets: [RateLimitBucket] = []

        appendLimit(
            object["rate_limit"] as? [String: Any],
            id: "codex",
            name: nil,
            into: &buckets
        )

        if let additional = object["additional_rate_limits"] as? [[String: Any]] {
            for (index, entry) in additional.enumerated() {
                let id = string(entry["metered_feature"]) ?? string(entry["limit_name"]) ?? "additional-\(index + 1)"
                appendLimit(
                    entry["rate_limit"] as? [String: Any],
                    id: id,
                    name: string(entry["limit_name"]),
                    into: &buckets
                )
            }
        }

        var seen = Set<String>()
        let unique: [RateLimitBucket] = buckets.filter { bucket in
            let reset = bucket.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            let used = bucket.usedPercent.map { String($0) } ?? "unknown"
            let key = "\(bucket.id)|\(bucket.window.rawValue)|\(used)|\(reset)"
            return seen.insert(key).inserted
        }
        return ParsedRateLimits(buckets: unique, planType: plan, parsedAt: now)
    }

    private static func appendLimit(_ raw: [String: Any]?, id: String, name: String?, into buckets: inout [RateLimitBucket]) {
        guard let raw else { return }
        appendWindow(raw["primary_window"], id: id, name: name, window: .primary, into: &buckets)
        appendWindow(raw["secondary_window"], id: id, name: name, window: .secondary, into: &buckets)
    }

    private static func appendWindow(_ raw: Any?, id: String, name: String?, window: RateLimitBucket.Window, into buckets: inout [RateLimitBucket]) {
        guard let raw = raw as? [String: Any] else { return }
        let used = number(raw["used_percent"]).flatMap { (0...100).contains($0) && $0.isFinite ? $0 : nil }
        let minutes = number(raw["limit_window_seconds"]).flatMap { seconds -> Int? in
            guard seconds.isFinite, seconds > 0, seconds <= Double(Int.max) else { return nil }
            return Int((seconds / 60).rounded(.up))
        }
        let reset = number(raw["reset_at"]).flatMap { seconds -> Date? in
            guard seconds.isFinite, seconds > 0, seconds < 4_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        buckets.append(RateLimitBucket(id: id, name: name, window: window, windowDurationMinutes: minutes, usedPercent: used, resetsAt: reset))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber,
           String(cString: number.objCType) != "c" {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
