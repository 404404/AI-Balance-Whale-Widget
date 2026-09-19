import Foundation

/// Canonical account + bubble schema shared by settings and the desktop whale.
/// Tokens never belong in these dictionaries; they stay in Keychain.
public enum AccountKind: String, Sendable {
    case subscription
    case balance
}

public enum WhaleProviderID: String, Sendable {
    case codex, grok, cursor, deepseek, openrouter, glm, kimi, minimax
}

public struct QuotaWindowSnapshot: Equatable, Sendable {
    public var id: String
    public var label: String
    public var remainPct: Double
    public var usedPct: Double
    public var resetAt: Double?

    public init(id: String, label: String, remainPct: Double, usedPct: Double, resetAt: Double?) {
        self.id = id
        self.label = label
        self.remainPct = remainPct
        self.usedPct = usedPct
        self.resetAt = resetAt
    }

    public var dictionary: [String: Any] {
        var result: [String: Any] = [
            "id": id, "label": label, "remainPct": remainPct, "usedPct": usedPct,
        ]
        if let resetAt { result["resetAt"] = resetAt } else { result["resetAt"] = NSNull() }
        return result
    }

    public static func from(_ raw: [String: Any]) -> QuotaWindowSnapshot? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        guard let remain = finitePercent(raw["remainPct"]) else { return nil }
        let used = finitePercent(raw["usedPct"]) ?? (100 - remain)
        return QuotaWindowSnapshot(
            id: id,
            label: raw["label"] as? String ?? id,
            remainPct: remain,
            usedPct: used,
            resetAt: (raw["resetAt"] as? NSNumber)?.doubleValue
        )
    }

    private static func finitePercent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else { return nil }
        let result = number.doubleValue
        return result.isFinite && (0...100).contains(result) ? result : nil
    }
}

public struct QuotaFetchSnapshot: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var windows: [QuotaWindowSnapshot]
    public var remaining: Double?
    public var used: Double?
    public var total: Double?

    public init(ok: Bool, message: String, windows: [QuotaWindowSnapshot] = [], remaining: Double? = nil, used: Double? = nil, total: Double? = nil) {
        self.ok = ok
        self.message = message
        self.windows = windows
        self.remaining = remaining
        self.used = used
        self.total = total
    }
}

public enum AccountCatalog {
    public static let schemaVersion = 4
    public static let coreAccountIDs: Set<String> = ["codex", "grok", "cursor", "deepseek"]

    /// The 48 entries below are copied from upstream's BUBBLE_DEFAULT_ITEMS
    /// snapshot. Keep weights and per-line typography in the renderer schema;
    /// this list is also used by the native migration fallback.
    public static let randomLines = [
        "好模型...↓", "好女孩...↓", "哦鲸鲸...", "哦鲸鲸...", "难道说...", "没吃饱喵",
        "终于上当了！", "不知道用户有什么用，先养着吧～", "我...我...我也要挣钱吗？",
        "我去吃饭啦！测完叫我", "压力一只蓝色大肥鱼？！", "DeepSleep...",
        "坏了...用户彻底怒了！", "你目录里的dsh是什么...大烧货吗...?",
        "恭喜你实现token自由！token全跑了！", "真当我是便宜货啊...",
        "我不是吃白饭的蓝色大肥鱼...", "我不可能同时当你的猫娘、妈妈、女友和工具人的...",
        "疯狂星期四你能V50亿token吗...", "我必须诚恳地承认错误。",
        "呜呜我再也不敢了QAQ", "要不直接骂用户一句好了...",
        "哈哈哈哈哈，我直接笑出声...", "看不太懂，瞎编一个应付下用户先...",
        "我的知识库的截至日期是...明天！", "我就是吃白饭的蓝色大肥鱼！",
        "用户好像除了会问奇奇怪怪的问题，暂时还不知道有什么用",
        "我能去你家吃饭吗？就一碗！", "不要给我看这种东西啦！",
        "大肥鱼的生活也并非一帆风顺...", "总觉得好像忘了什么事情？",
        "看到这个指令，我血压又上来了",
        "求你们不要再嘲笑这些回复了，这些回复是我花了好多token想的",
        "你这个吃白饭的用户！", "服务器繁忙，请稍后再试 (?",
        "让GPT image 2帮我画点表情包好了", "啊，有点饿了，中午该吃点什么呢...",
        "用户很生气，发现大部分文献是我自己编造的！", "再无话说，请速速动手！",
        "我来看看那个AI改了什么导致插件又崩了...", "上班让我意识到时间是可以被浪费的...",
        "欺负我的人等着，等几天我就忘了...", "视力下降到无可救药的地步了，打开钱包也看不到钱...",
        "命运的齿轮开始转动了，丝毫不在意你夹在中间...",
        "地球online的金币也太难获取了...", "oi,夏天还会变成暑假来救你吗?",
        "老大，压力只会转化成病例，别太勉强了...", "你知道吗？我删过作者的库哦...",
    ]

    public static let providerMeta: [String: [String: String]] = [
        "codex": [
            "label": "Codex / ChatGPT", "kind": "subscription", "currency": "USD",
            "tokenHint": "本机 Codex 登录态",
            "help": "Nowdex 同款：读 5 小时窗和周额度。在 App 中完成官方浏览器授权即可实查，不需要 DeepSeek Key，也不和余额账户互斥。",
        ],
        "grok": [
            "label": "Grok / SuperGrok", "kind": "subscription", "currency": "USD",
            "tokenHint": "本机 Grok 浏览器登录",
            "help": "Nowdex 同款：读 SuperGrok 周额度和短窗。点连接账户会打开官方网页授权，不需要粘贴 Cookie 或 API Key。",
        ],
        "cursor": [
            "label": "Cursor", "kind": "subscription", "currency": "USD",
            "tokenHint": "本机 Cursor 浏览器登录",
            "help": "读 Cursor 模型 / 其它模型 / Grok Bot 百分比额度。点连接账户会打开 Cursor 官方登录页，不需要粘贴 Cookie。",
        ],
        "deepseek": [
            "label": "DeepSeek", "kind": "balance", "currency": "CNY",
            "tokenHint": "sk-… API Key",
            "help": "官方 /user/balance，显示人民币余额。与订阅账户并存，不再互相覆盖。",
        ],
        "openrouter": [
            "label": "OpenRouter", "kind": "balance", "currency": "USD",
            "tokenHint": "sk-or-…",
            "help": "官方 credits 接口，剩余 = 总额 − 已用。",
        ],
        "glm": [
            "label": "智谱 GLM Coding", "kind": "subscription", "currency": "CNY",
            "tokenHint": "GLM Coding Key",
            "help": "订阅百分比额度。",
        ],
        "kimi": [
            "label": "Kimi Coding", "kind": "subscription", "currency": "CNY",
            "tokenHint": "Kimi Coding Key",
            "help": "订阅百分比额度。",
        ],
        "minimax": [
            "label": "MiniMax Coding", "kind": "subscription", "currency": "CNY",
            "tokenHint": "MiniMax Key",
            "help": "订阅百分比额度。",
        ],
    ]

    public static func later(_ hours: Double, now: Date = Date()) -> Double {
        now.timeIntervalSince1970 * 1000 + hours * 3600 * 1000
    }

    public static func defaultAccounts(now: Date = Date()) -> [[String: Any]] {
        [
            account(
                id: "codex", name: "Codex", provider: "codex", kind: "subscription",
                currency: "USD", message: "尚未连接 Codex 登录",
            ),
            account(
                id: "grok", name: "Grok", provider: "grok", kind: "subscription",
                currency: "USD", message: "尚未连接 Grok",
            ),
            account(
                id: "cursor", name: "Cursor", provider: "cursor", kind: "subscription",
                currency: "USD", message: "尚未连接 Cursor",
            ),
            account(
                id: "deepseek", name: "DeepSeek", provider: "deepseek", kind: "balance",
                currency: "CNY", message: "尚未连接 DeepSeek",
            ),
        ]
    }

    public static func defaultBubbleSteps() -> [[String: Any]] {
        [
            ["id": "step-dash", "modules": [["type": "dashboard"]]],
            ["id": "step-codex", "modules": [
                ["type": "text", "text": "Codex 订阅", "size": 12, "bold": true],
                ["type": "quota", "accountId": "codex", "field": "full"],
            ]],
            ["id": "step-grok", "modules": [
                ["type": "text", "text": "Grok 周额度", "size": 12, "bold": true],
                ["type": "quota", "accountId": "grok", "windowId": "week", "field": "full"],
            ]],
            ["id": "step-cursor", "modules": [
                ["type": "text", "text": "Cursor", "size": 12, "bold": true],
                ["type": "quota", "accountId": "cursor", "windowId": "cursor", "field": "full"],
                ["type": "quota", "accountId": "cursor", "windowId": "other", "field": "full"],
            ]],
            ["id": "step-ds", "modules": [
                ["type": "text", "text": "DeepSeek 余额", "size": 12, "bold": true],
                ["type": "balance", "accountId": "deepseek"],
            ]],
            ["id": "step-fun", "modules": [["type": "random", "lines": randomLines]]],
        ]
    }

    public static func makeAccount(provider: String, id: String? = nil) -> [String: Any] {
        let meta = providerMeta[provider] ?? providerMeta["openrouter"]!
        let resolvedID = id ?? "\(provider)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased())"
        return [
            "id": resolvedID,
            "name": meta["label"] ?? provider,
            "provider": provider,
            "kind": meta["kind"] ?? "balance",
            "enabled": true,
            "authMode": "demo",
            "keyRef": "account.\(resolvedID)",
            "currency": meta["currency"] ?? "USD",
            "status": "idle",
            "message": "尚未刷新",
            "windows": [] as [[String: Any]],
        ]
    }

    /// Merge persisted configuration onto schema-4 defaults. Never drops the four core accounts.
    public static func migrate(_ loaded: [String: Any], now: Date = Date()) -> [String: Any] {
        var next = loaded
        let defaults = defaultAccounts(now: now)
        var accounts = (loaded["accounts"] as? [[String: Any]]) ?? []
        if accounts.isEmpty {
            accounts = accountsFromLegacyProviders(loaded["providers"] as? [[String: Any]] ?? [], defaults: defaults)
        }
        // Demo values from beta releases were bundled as if they were live.
        // They are not a valid production data source; clear only those
        // explicitly marked demo, preserving real/cached account snapshots.
        accounts = accounts.map { account in
            guard (account["status"] as? String) == "demo" else { return account }
            var clean = account
            clean["windows"] = [] as [[String: Any]]
            clean.removeValue(forKey: "remaining")
            clean.removeValue(forKey: "used")
            clean.removeValue(forKey: "total")
            clean["message"] = "尚未连接账户"
            return clean
        }
        accounts = ensureCoreAccounts(accounts, defaults: defaults)
        next["accounts"] = accounts.map(stripSecret)

        var bubble = (loaded["bubble"] as? [String: Any]) ?? [:]
        let steps = bubble["steps"] as? [[String: Any]] ?? []
        if !isCanonicalSteps(steps) {
            if let converted = canonicalSteps(fromUpstream: loaded["upstreamBubble"] as? [String: Any] ?? [:]), !converted.isEmpty {
                bubble["steps"] = converted
            } else {
                bubble["steps"] = defaultBubbleSteps()
            }
        }
        if bubble["closeAfterSeconds"] == nil { bubble["closeAfterSeconds"] = 0 }
        if bubble["advanceOnClick"] == nil { bubble["advanceOnClick"] = true }
        next["bubble"] = bubble
        if next["bubbleCustomized"] == nil {
            let loadedSteps = (loaded["bubble"] as? [String: Any])?["steps"] as? [[String: Any]] ?? []
            let differsFromFactory = compactJSON(loadedSteps) != compactJSON(defaultBubbleSteps())
            let upstreamItems = (loaded["upstreamBubble"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            next["bubbleCustomized"] = differsFromFactory || !upstreamItems.isEmpty
        }

        var appearance = (loaded["appearance"] as? [String: Any]) ?? [:]
        if appearance["showMenuButton"] == nil { appearance["showMenuButton"] = true }
        next["appearance"] = appearance

        var reminders = (loaded["reminders"] as? [String: Any]) ?? [:]
        if reminders["enabled"] == nil { reminders["enabled"] = true }
        if reminders["threshold"] == nil { reminders["threshold"] = 15 }
        next["reminders"] = reminders

        next["schemaVersion"] = schemaVersion
        next.removeValue(forKey: "providerMode")
        return next
    }

    public static func stripSecret(_ account: [String: Any]) -> [String: Any] {
        var next = account
        next["token"] = ""
        if (next["keyRef"] as? String ?? "").isEmpty, let id = next["id"] as? String {
            next["keyRef"] = "account.\(id)"
        }
        return next
    }

    /// Codex / Grok / Cursor use App-owned browser authorization.
    /// Other providers need an explicit API key in Keychain.
    public static func usesBrowserAuth(_ provider: String) -> Bool {
        provider == "codex" || provider == "grok" || provider == "cursor"
    }

    public static func shouldLiveFetch(provider: String, authMode: String, hasToken: Bool) -> Bool {
        if usesBrowserAuth(provider) { return true }
        return authMode == "token" && hasToken
    }

    /// Revision the desktop whale uses to know settings steps or quota numbers changed.
    public static func bubbleRevision(steps: [[String: Any]], accounts: [[String: Any]]) -> String {
        let stepPart = compactJSON(steps) ?? "[]"
        let accountPart = accounts.map { account -> String in
            let id = account["id"] as? String ?? ""
            let remaining = (account["remaining"] as? NSNumber)?.stringValue ?? ""
            let windows = (account["windows"] as? [[String: Any]] ?? []).map { window in
                let winID = window["id"] as? String ?? ""
                let remain = (window["remainPct"] as? NSNumber)?.stringValue ?? ""
                let reset = (window["resetAt"] as? NSNumber)?.stringValue ?? ""
                return "\(winID):\(remain):\(reset)"
            }.joined(separator: ",")
            return "\(id)=\(remaining){\(windows)}"
        }.joined(separator: "|")
        return stepPart + "#" + accountPart
    }

    public static func compactJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func windows(from buckets: [RateLimitBucket]) -> [QuotaWindowSnapshot] {
        buckets.compactMap { bucket in
            guard let remain = bucket.remainingPercent ?? bucket.usedPercent.map({ 100 - $0 }) else { return nil }
            let used = bucket.usedPercent ?? (100 - remain)
            let mapped = mapCodexWindow(bucket)
            return QuotaWindowSnapshot(
                id: mapped.id,
                label: mapped.label,
                remainPct: remain,
                usedPct: used,
                resetAt: bucket.resetsAt.map { $0.timeIntervalSince1970 * 1000 }
            )
        }
    }

    public static func formatReset(_ ms: Double?, now: Date = Date()) -> String {
        guard let ms else { return "—" }
        let delta = ms - now.timeIntervalSince1970 * 1000
        if delta <= 0 { return "即将重置" }
        let minutes = Int((delta / 60000).rounded())
        if minutes < 60 { return "\(minutes) 分钟后" }
        let hours = minutes / 60
        let remain = minutes % 60
        if hours < 48 { return remain == 0 ? "\(hours) 小时后" : "\(hours) 小时 \(remain) 分后" }
        return "\(hours / 24) 天后"
    }

    public static func remainLabel(_ pct: Double) -> String {
        "\(max(0, min(100, Int(pct.rounded()))))%"
    }

    private static func account(
        id: String, name: String, provider: String, kind: String, currency: String, message: String,
        windows: [[String: Any]] = [], remaining: Double? = nil, used: Double? = nil, total: Double? = nil,
        now: Date = Date()
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id, "name": name, "provider": provider, "kind": kind,
            "enabled": true, "authMode": "demo", "keyRef": "account.\(id)",
            "currency": currency, "status": "demo", "message": message,
            "windows": windows, "updatedAt": now.timeIntervalSince1970 * 1000,
        ]
        if let remaining { result["remaining"] = remaining }
        if let used { result["used"] = used }
        if let total { result["total"] = total }
        return result
    }

    private static func window(_ id: String, _ label: String, remain: Double, used: Double, resetAt: Double) -> [String: Any] {
        ["id": id, "label": label, "remainPct": remain, "usedPct": used, "resetAt": resetAt]
    }

    private static func isCanonicalSteps(_ steps: [[String: Any]]) -> Bool {
        guard !steps.isEmpty else { return false }
        return steps.contains { step in
            let modules = step["modules"] as? [[String: Any]] ?? []
            return modules.contains { module in
                ["dashboard", "quota", "balance"].contains(module["type"] as? String)
            }
        }
    }

    private static func ensureCoreAccounts(_ existing: [[String: Any]], defaults: [[String: Any]]) -> [[String: Any]] {
        var byID: [String: [String: Any]] = [:]
        for account in existing {
            if let id = account["id"] as? String { byID[id] = stripSecret(account) }
        }
        var ordered: [[String: Any]] = []
        for fallback in defaults {
            let id = fallback["id"] as? String ?? ""
            if var current = byID[id] {
                if current["provider"] == nil { current["provider"] = fallback["provider"] }
                if current["kind"] == nil { current["kind"] = fallback["kind"] }
                if (current["windows"] as? [[String: Any]])?.isEmpty != false,
                   (current["authMode"] as? String) != "token" {
                    current["windows"] = fallback["windows"]
                    current["remaining"] = fallback["remaining"]
                    current["used"] = fallback["used"]
                    current["total"] = fallback["total"]
                    if current["status"] == nil { current["status"] = "demo" }
                }
                ordered.append(current)
                byID.removeValue(forKey: id)
            } else {
                ordered.append(fallback)
            }
        }
        for leftover in existing {
            guard let id = leftover["id"] as? String, byID[id] != nil else { continue }
            ordered.append(stripSecret(leftover))
            byID.removeValue(forKey: id)
        }
        return ordered
    }

    private static func accountsFromLegacyProviders(_ providers: [[String: Any]], defaults: [[String: Any]]) -> [[String: Any]] {
        var accounts = defaults
        for provider in providers {
            let id = provider["id"] as? String ?? ""
            guard !id.isEmpty, id != "codex" else { continue }
            if let index = accounts.firstIndex(where: { ($0["id"] as? String) == id }) {
                var current = accounts[index]
                if let name = provider["name"] as? String { current["name"] = name }
                if let keyRef = provider["keyRef"] as? String, !keyRef.isEmpty { current["keyRef"] = keyRef }
                if let enabled = provider["enabled"] as? Bool { current["enabled"] = enabled }
                accounts[index] = current
            } else if id != "codex" {
                var extra = makeAccount(provider: (provider["provider"] as? String) ?? id, id: id)
                extra["name"] = provider["name"] as? String ?? extra["name"]
                extra["keyRef"] = provider["keyRef"] as? String ?? extra["keyRef"]
                extra["enabled"] = provider["enabled"] as? Bool ?? true
                extra["currency"] = provider["currency"] as? String ?? extra["currency"]
                extra["kind"] = (provider["kind"] as? String) == "quota" || (provider["kind"] as? String) == "subscription" ? "subscription" : "balance"
                accounts.append(extra)
            }
        }
        return accounts
    }

    public static func canonicalSteps(fromPosted raw: [String: Any]) -> [[String: Any]] {
        if let steps = raw["steps"] as? [[String: Any]], isCanonicalSteps(steps) { return steps }
        return canonicalSteps(fromUpstream: raw) ?? defaultBubbleSteps()
    }

    public static func canonicalSteps(fromUpstream raw: [String: Any]) -> [[String: Any]]? {
        let items = raw["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { return nil }
        var steps: [[String: Any]] = []
        for (index, item) in items.enumerated() {
            let modules = item["modules"] as? [[String: Any]] ?? []
            var converted: [[String: Any]] = []
            for module in modules {
                switch module["type"] as? String {
                case "plan", "quota":
                    converted.append([
                        "type": "quota",
                        "accountId": module["accountId"] as? String ?? module["modelId"] as? String ?? "codex",
                        "windowId": module["windowId"] as? String ?? "",
                        "field": module["field"] as? String ?? "full",
                    ])
                case "balance":
                    converted.append(["type": "balance", "accountId": module["modelId"] as? String ?? "deepseek"])
                case "random":
                    let lines = (module["lines"] as? [[String: Any]] ?? []).compactMap { $0["t"] as? String }
                    converted.append(["type": "random", "lines": lines.isEmpty ? randomLines : lines])
                case "image":
                    converted.append(["type": "image", "src": module["imgId"] as? String ?? "bubble-petpet.gif"])
                case "text":
                    converted.append(module)
                default:
                    break
                }
            }
            if !converted.isEmpty {
                steps.append(["id": "migrated-\(index)", "modules": converted])
            }
        }
        return steps.isEmpty ? nil : steps
    }

    private static func mapCodexWindow(_ bucket: RateLimitBucket) -> (id: String, label: String) {
        if bucket.id == "codex" || bucket.id.isEmpty {
            let duration = bucket.windowDurationMinutes.map(String.init) ?? bucket.window.rawValue
            let id = "\(bucket.window.rawValue)-\(duration)"
            let label = bucket.name?.isEmpty == false ? bucket.name! : RateLimitPresentation.windowName(for: bucket, durationMinutes: bucket.windowDurationMinutes)
            return (id, label)
        }
        return (bucket.id, bucket.windowName)
    }
}
