import Foundation
import CodexCore

enum ProviderStatus: String, Codable {
    case idle
    case loading
    case ready
    case stale
    case cliMissing
    case notLoggedIn
    case apiKeyUnsupported
    case unsupported
    case offline
    case error
}

struct ProviderState {
    var status: ProviderStatus = .idle
    var message: String = "等待查询 Codex 额度"
    var email: String?
    var planType: String?
    var accountKey: String?
    var buckets: [RateLimitBucket] = []
    var lastUpdated: Date?
    var cliPath: String?
    var cliVersion: String?
}

private struct CachedSnapshot: Codable {
    let accountKey: String
    let email: String?
    let planType: String?
    let buckets: [RateLimitBucket]
    let lastUpdated: Date
}

private final class PendingRequest {
    let completion: ([String: Any]?, ProviderError?) -> Void
    let timeout: DispatchWorkItem

    init(completion: @escaping ([String: Any]?, ProviderError?) -> Void, timeout: DispatchWorkItem) {
        self.completion = completion
        self.timeout = timeout
    }
}

enum ProviderError: LocalizedError {
    case cliMissing
    case launch(String)
    case timeout
    case processExited
    case protocolError(String)
    case serverError(String)
    case notLoggedIn
    case apiKeyUnsupported
    case unsupported(String)
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing: return "没有找到 Codex CLI"
        case .launch(let message): return "无法启动 Codex app-server：\(message)"
        case .timeout: return "Codex app-server 响应超时"
        case .processExited: return "Codex app-server 已退出"
        case .protocolError(let message): return "Codex 协议错误：\(message)"
        case .serverError(let message): return message
        case .notLoggedIn: return "Codex 尚未登录 ChatGPT 账号"
        case .apiKeyUnsupported: return "当前是 API Key 模式，无法读取 ChatGPT 订阅额度"
        case .unsupported(let message): return message
        case .offline(let message): return "额度查询失败：\(message)"
        }
    }
}

enum CodexLocator {
    static func executable(configuredPath: String) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((configuredPath as NSString).expandingTildeInPath)
        }

        let home = NSHomeDirectory()
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        var seen = Set<String>()
        for candidate in candidates {
            let path = (candidate as NSString).standardizingPath
            guard seen.insert(path).inserted, fileManager.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func version(at executable: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            return nil
        }
    }
}

final class CodexAppServerClient {
    var onStateChange: ((ProviderState) -> Void)?

    private let preferences: AppPreferences
    private let callbackQueue = DispatchQueue.main
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var initialized = false
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var refreshInFlight = false
    private var sleeping = false
    private var state = ProviderState()
    private var cache: CachedSnapshot?

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences
        cache = readCache()
    }

    func refresh() {
        callbackQueue.async { [weak self] in self?.refreshOnMain() }
    }

    func stop() {
        callbackQueue.async { [weak self] in self?.stopOnMain() }
    }

    func stopImmediately() {
        input = nil
        output?.readabilityHandler = nil
        output = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        initialized = false
        for pendingRequest in pending.values { pendingRequest.timeout.cancel() }
        pending.removeAll()
    }

    func setSleeping(_ value: Bool) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            sleeping = value
            if value { stopOnMain() } else { refreshOnMain() }
        }
    }

    private func refreshOnMain() {
        guard !sleeping else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        state.status = .loading
        state.message = "正在从 Codex app-server 查询额度…"
        emit()

        guard let executable = CodexLocator.executable(configuredPath: preferences.codexPath) else {
            finish(.cliMissing, message: "请安装 Codex CLI，或在设置中指定 codex 可执行文件路径")
            return
        }
        state.cliPath = executable.path
        state.cliVersion = CodexLocator.version(at: executable)

        ensureServer(executable: executable) { [weak self] error in
            guard let self else { return }
            if let error {
                finish(error, message: error.localizedDescription)
                return
            }
            readAccountAndLimits()
        }
    }

    private func ensureServer(executable: URL, completion: @escaping (ProviderError?) -> Void) {
        if process?.isRunning == true, initialized {
            completion(nil)
            return
        }
        stopOnMain()
        let newProcess = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        newProcess.executableURL = executable
        newProcess.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        let configuredHome = preferences.codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredHome.isEmpty {
            environment["CODEX_HOME"] = (configuredHome as NSString).expandingTildeInPath
        }
        newProcess.environment = environment
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr

        do {
            try newProcess.run()
        } catch {
            completion(.launch(error.localizedDescription))
            return
        }

        process = newProcess
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        initialized = false
        output?.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            do {
                let data = try handle.read(upToCount: 16 * 1024) ?? Data()
                if data.isEmpty { return }
                callbackQueue.async { self.consume(data) }
            } catch {
                callbackQueue.async { self.handleTransportFailure(.offline(error.localizedDescription)) }
            }
        }
        // Drain stderr but never record or surface it: it may contain sensitive CLI diagnostics.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = try? handle.read(upToCount: 16 * 1024)
        }
        newProcess.terminationHandler = { [weak self] _ in
            self?.callbackQueue.async { self?.handleTransportFailure(.processExited) }
        }

        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "ai_balance_whale",
                    "title": "AI Balance Whale",
                    "version": "0.1.0",
                ],
            ]
        ) { [weak self] _, error in
            guard let self else { return }
            if let error {
                completion(error)
                return
            }
            initialized = true
            sendNotification(method: "initialized", params: [:])
            completion(nil)
        }
    }

    private func readAccountAndLimits() {
        sendRequest(method: "account/read", params: ["refreshToken": false]) { [weak self] result, error in
            guard let self else { return }
            if let error { finish(error, message: error.localizedDescription); return }
            guard let result, let account = result["account"] as? [String: Any] else {
                state.accountKey = nil
                state.email = nil
                state.planType = nil
                state.buckets = []
                state.lastUpdated = nil
                finish(.notLoggedIn, message: "未检测到已登录的 ChatGPT 账号，请先在 Codex CLI 中登录")
                return
            }

            let accountType = (account["type"] as? String)?.lowercased()
            if accountType == "apikey" || accountType == "apiKey" {
                finish(.apiKeyUnsupported, message: "当前 Codex 使用 API Key；请切换到 ChatGPT 登录后才能读取订阅额度")
                return
            }
            if accountType == "amazonbedrock" || accountType == "personalaccesstoken" {
                finish(.unsupported("当前认证模式不提供 ChatGPT 订阅额度"), message: "当前认证模式不提供 ChatGPT 订阅额度")
                return
            }

            let email = account["email"] as? String
            let planType = account["planType"] as? String
            let key = accountKey(account)
            if key != state.accountKey {
                state.accountKey = key
                state.email = email
                state.planType = planType
                state.buckets = []
                state.lastUpdated = nil
                cache = cache?.accountKey == key ? cache : nil
            }
            state.email = email
            state.planType = planType

            sendRequest(method: "account/rateLimits/read", params: nil) { [weak self] limits, error in
                guard let self else { return }
                if let error {
                    useCacheOrFail(error: error)
                    return
                }
                guard let limits else {
                    useCacheOrFail(error: .protocolError("rateLimits/read 返回空响应"))
                    return
                }
                applyRateLimits(limits, accountKey: key, email: email, planType: planType)
                finishReady()
            }
        }
    }

    private func applyRateLimits(_ object: [String: Any], accountKey: String?, email: String?, planType: String?) {
        let parsed = RateLimitParser.parse(object)
        guard let accountKey else { return }
        state.accountKey = accountKey
        state.email = email
        state.planType = planType ?? parsed.planType
        state.buckets = parsed.buckets
        state.lastUpdated = Date()
        cache = CachedSnapshot(accountKey: accountKey, email: email, planType: state.planType, buckets: parsed.buckets, lastUpdated: Date())
        writeCache(cache)
    }

    private func handleNotification(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        switch method {
        case "account/rateLimits/updated":
            guard state.accountKey != nil else { return }
            let parsed = RateLimitParser.parse(message)
            guard !parsed.buckets.isEmpty else { return }
            state.buckets = parsed.buckets
            state.lastUpdated = Date()
            if state.status != .ready { state.status = .ready; state.message = "额度已由 Codex 更新" }
            if let cache, let key = state.accountKey {
                self.cache = CachedSnapshot(accountKey: key, email: cache.email, planType: cache.planType, buckets: parsed.buckets, lastUpdated: Date())
                writeCache(self.cache)
            }
            emit()
        case "account/updated":
            // Account identity may have changed. Re-read it before showing data;
            // cached buckets are never carried across an account key change.
            state.buckets = []
            state.lastUpdated = nil
            refreshOnMain()
        default:
            break
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = int(object["id"]), let request = pending.removeValue(forKey: id) {
                request.timeout.cancel()
                request.completion(object["result"] as? [String: Any], parseError(object["error"]))
            } else if object["id"] == nil {
                handleNotification(object)
            }
        }
    }

    private func sendRequest(method: String, params: [String: Any]?, completion: @escaping ([String: Any]?, ProviderError?) -> Void) {
        let id = nextRequestID
        nextRequestID += 1
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let request = pending.removeValue(forKey: id) else { return }
            request.completion(nil, .timeout)
        }
        pending[id] = PendingRequest(completion: completion, timeout: timeout)
        callbackQueue.asyncAfter(deadline: .now() + 12, execute: timeout)
        writeMessage(["method": method, "id": id, "params": params ?? [:]])
    }

    private func sendNotification(method: String, params: [String: Any]) {
        writeMessage(["method": method, "params": params])
    }

    private func writeMessage(_ object: [String: Any]) {
        guard let input, JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do {
            try input.write(contentsOf: data)
            try input.write(contentsOf: Data([10]))
        } catch {
            handleTransportFailure(.offline(error.localizedDescription))
        }
    }

    private func parseError(_ object: Any?) -> ProviderError? {
        guard let object = object as? [String: Any] else { return nil }
        let message = object["message"] as? String ?? "Codex app-server 返回未知错误"
        let lower = message.lowercased()
        if lower.contains("unauthorized") || lower.contains("not logged") { return .notLoggedIn }
        return .serverError(message)
    }

    private func handleTransportFailure(_ error: ProviderError) {
        guard refreshInFlight || state.status == .ready else { return }
        initialized = false
        useCacheOrFail(error: error)
    }

    private func useCacheOrFail(error: ProviderError) {
        if let cache, cache.accountKey == state.accountKey {
            state.status = .stale
            state.message = "查询失败，显示同账号缓存（已过期）：\(error.localizedDescription)"
            state.email = cache.email
            state.planType = cache.planType
            state.buckets = cache.buckets
            state.lastUpdated = cache.lastUpdated
            emit()
            refreshInFlight = false
        } else {
            finish(error, message: error.localizedDescription)
        }
    }

    private func finishReady() {
        refreshInFlight = false
        state.status = .ready
        state.message = state.buckets.isEmpty ? "账号已登录，但暂未返回额度窗口" : "Codex 额度已更新"
        emit()
    }

    private func finish(_ error: ProviderError, message: String) {
        refreshInFlight = false
        state.status = status(for: error)
        state.message = message
        emit()
    }

    private func status(for error: ProviderError) -> ProviderStatus {
        switch error {
        case .cliMissing: return .cliMissing
        case .notLoggedIn: return .notLoggedIn
        case .apiKeyUnsupported: return .apiKeyUnsupported
        case .unsupported: return .unsupported
        case .offline, .timeout, .processExited: return .offline
        default: return .error
        }
    }

    private func stopOnMain() {
        output?.readabilityHandler = nil
        input = nil
        output = nil
        initialized = false
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        for request in pending.values { request.timeout.cancel() }
        pending.removeAll()
    }

    private func accountKey(_ account: [String: Any]) -> String? {
        for key in ["id", "accountId", "chatgptAccountId", "email"] {
            if let value = account[key] as? String, !value.isEmpty { return value }
        }
        if let type = account["type"] as? String { return "type:\(type)" }
        return nil
    }

    private func emit() { onStateChange?(state) }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Balance Whale", isDirectory: true)
        return base.appendingPathComponent("codex-rate-limit.json")
    }

    private func readCache() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachedSnapshot.self, from: data)
    }

    private func writeCache(_ value: CachedSnapshot?) {
        guard let value else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: cacheURL, options: .atomic) }
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
