import Foundation

/// Protocol sketches from the Nowdex web reference, rewritten as pure parsers
/// so fixture tests can run without network or AppKit.
public enum QuotaJSONParser {
    public static func parse(provider: String, object: Any) -> QuotaFetchSnapshot {
        switch provider {
        case "deepseek": return parseDeepSeek(object)
        case "openrouter": return parseOpenRouter(object)
        case "grok": return parseGrok(object)
        case "cursor": return parseCursor(object)
        case "glm": return parseGLM(object)
        case "kimi": return parseKimi(object)
        case "minimax": return parseMiniMax(object)
        case "codex": return parseCodexHTTP(object)
        default: return QuotaFetchSnapshot(ok: false, message: "未知厂商")
        }
    }

    public static func parseDeepSeek(_ object: Any) -> QuotaFetchSnapshot {
        guard let remaining = number(at: "balance_infos.0.total_balance", in: object) else {
            return QuotaFetchSnapshot(ok: false, message: "余额字段无法解析")
        }
        return QuotaFetchSnapshot(ok: true, message: "DeepSeek 余额已更新", remaining: remaining)
    }

    public static func parseOpenRouter(_ object: Any) -> QuotaFetchSnapshot {
        guard let total = number(at: "data.total_credits", in: object) else {
            return QuotaFetchSnapshot(ok: false, message: "credits 无法解析")
        }
        let used = number(at: "data.total_usage", in: object) ?? 0
        return QuotaFetchSnapshot(ok: true, message: "OpenRouter 已更新", remaining: total - used, used: used, total: total)
    }

    public static func parseGrok(_ object: Any) -> QuotaFetchSnapshot {
        let used = number(at: "used_percent", in: object) ?? number(at: "weekly_used_percent", in: object)
        let remain = used.map { 100 - $0 } ?? number(at: "remaining_percent", in: object)
        guard let remain else { return QuotaFetchSnapshot(ok: false, message: "Grok 额度字段无法解析") }
        let reset = milliseconds(number(at: "reset_at", in: object) ?? number(at: "weekly_reset_at", in: object))
        let shortUsed = number(at: "short_used_percent", in: object)
        var windows = [
            QuotaWindowSnapshot(id: "week", label: "本周", remainPct: remain, usedPct: 100 - remain, resetAt: reset),
        ]
        if let shortUsed {
            let shortRemain = 100 - (shortUsed <= 1 ? shortUsed * 100 : shortUsed)
            windows.append(QuotaWindowSnapshot(id: "2h", label: "短窗", remainPct: shortRemain, usedPct: 100 - shortRemain, resetAt: milliseconds(number(at: "short_reset_at", in: object))))
        }
        return QuotaFetchSnapshot(ok: true, message: "Grok 周额度已更新", windows: windows)
    }

    public static func parseCursor(_ object: Any) -> QuotaFetchSnapshot {
        var windows: [QuotaWindowSnapshot] = []
        let plan = pick(object, "planUsage") as? [String: Any]
        if let auto = number(at: "planUsage.autoPercentUsed", in: object) ?? number(from: plan?["autoPercentUsed"]) {
            let used = auto <= 1 ? auto * 100 : auto
            windows.append(QuotaWindowSnapshot(id: "cursor", label: "Cursor 模型", remainPct: 100 - used, usedPct: used, resetAt: nil))
        }
        if let api = number(at: "planUsage.apiPercentUsed", in: object) ?? number(from: plan?["apiPercentUsed"]) {
            let used = api <= 1 ? api * 100 : api
            windows.append(QuotaWindowSnapshot(id: "other", label: "其它模型", remainPct: 100 - used, usedPct: used, resetAt: nil))
        }
        if let bot = number(at: "planUsage.botPercentUsed", in: object) ?? number(at: "grokBot.used_percent", in: object) {
            let used = bot <= 1 ? bot * 100 : bot
            windows.append(QuotaWindowSnapshot(id: "bot", label: "Grok Bot", remainPct: 100 - used, usedPct: used, resetAt: nil))
        }
        if windows.isEmpty, let remainCents = number(from: plan?["remaining"]), let limit = number(from: plan?["limit"]), limit != 0 {
            let remainPct = (remainCents / limit) * 100
            windows.append(QuotaWindowSnapshot(id: "plan", label: "套餐", remainPct: remainPct, usedPct: 100 - remainPct, resetAt: nil))
        }
        guard !windows.isEmpty else { return QuotaFetchSnapshot(ok: false, message: "Cursor 用量无法解析") }
        return QuotaFetchSnapshot(ok: true, message: "Cursor 额度已更新", windows: windows)
    }

    public static func parseGLM(_ object: Any) -> QuotaFetchSnapshot {
        guard let used = number(at: "data.limits.0.TOKENS_LIMIT.percentage", in: object) else {
            return QuotaFetchSnapshot(ok: false, message: "GLM 额度无法解析")
        }
        let pct = used <= 1 ? used * 100 : used
        return QuotaFetchSnapshot(
            ok: true, message: "GLM 已更新",
            windows: [QuotaWindowSnapshot(id: "plan", label: "套餐", remainPct: 100 - pct, usedPct: pct, resetAt: nil)]
        )
    }

    public static func parseKimi(_ object: Any) -> QuotaFetchSnapshot {
        let remain = number(at: "current_remaining_percent", in: object) ?? 0
        return QuotaFetchSnapshot(
            ok: true, message: "Kimi 已更新",
            windows: [QuotaWindowSnapshot(id: "plan", label: "套餐", remainPct: remain, usedPct: 100 - remain, resetAt: nil)]
        )
    }

    public static func parseMiniMax(_ object: Any) -> QuotaFetchSnapshot {
        let remain = number(at: "model_remains.0.current_interval_remaining_percent", in: object) ?? 0
        return QuotaFetchSnapshot(
            ok: true, message: "MiniMax 已更新",
            windows: [QuotaWindowSnapshot(id: "plan", label: "套餐", remainPct: remain, usedPct: 100 - remain, resetAt: nil)]
        )
    }

    public static func parseCodexHTTP(_ object: Any) -> QuotaFetchSnapshot {
        let parsed = WhamUsageParser.parse(object as? [String: Any] ?? [:])
        let windows = AccountCatalog.windows(from: parsed.buckets)
        guard !windows.isEmpty else { return QuotaFetchSnapshot(ok: false, message: "Codex 用量结构无法识别") }
        return QuotaFetchSnapshot(ok: true, message: "Codex 订阅额度已更新", windows: windows)
    }

    public static func number(at path: String, in object: Any) -> Double? {
        number(from: pick(object, path))
    }

    public static func pick(_ object: Any, _ path: String) -> Any? {
        var current: Any = object
        let normalized = path.replacingOccurrences(of: "[", with: ".").replacingOccurrences(of: "]", with: "")
        for component in normalized.split(separator: ".").map(String.init) where !component.isEmpty {
            if let index = Int(component) {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            } else {
                guard let dictionary = current as? [String: Any], let next = dictionary[component] else { return nil }
                current = next
            }
        }
        return current
    }

    public static func number(from value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func milliseconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }
}
