import Foundation
import CodexCore

enum ProviderStatus: String, Codable { case idle, loading, ready, stale, cliMissing, notLoggedIn, apiKeyUnsupported, unsupported, offline, error }

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
    var authSource: String?
    /// Set by the coordinator for each refresh cycle. It is not a secret.
    var requestID: String?
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
    case timeout(stage: String, seconds: Int)
    case processExited(stage: String)
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
        case .timeout(let stage, let seconds): return "Codex app-server 在 \(stage) 阶段等待 \(seconds) 秒超时；请检查 CLI 路径、CODEX_HOME、登录状态及网络设置"
        case .processExited(let stage): return "Codex app-server 在 \(stage) 阶段退出"
        case .protocolError(let message): return "Codex 协议错误：\(message)"
        case .serverError(let message): return message
        case .notLoggedIn: return "Codex 尚未登录 ChatGPT 账号，请先在 Codex CLI 中登录"
        case .apiKeyUnsupported: return "当前是 API Key 模式，无法读取 ChatGPT 订阅额度"
        case .unsupported(let message): return message
        case .offline(let message): return "额度查询失败：\(message)"
        }
    }
}

enum CodexLocator {
    static func expandingPath(_ raw: String) -> String {
        (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    static func effectiveHome(configuredHome: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let configured = expandingPath(configuredHome)
        if !configured.isEmpty { return URL(fileURLWithPath: configured).standardizedFileURL }
        if let inherited = environment["CODEX_HOME"], !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandingPath(inherited)).standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true).standardizedFileURL
    }

    static func connectionInfo(configuredPath: String, configuredHome: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any] {
        let configured = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executableURL = executable(configuredPath: configuredPath)
        let home = effectiveHome(configuredHome: configuredHome, environment: environment)
        let fileManager = FileManager.default
        var result: [String: Any] = [
            "configuredPath": configured,
            "pathSource": configured.isEmpty ? "auto" : "manual",
            "homeSource": configuredHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (environment["CODEX_HOME"] == nil ? "default" : "environment") : "manual",
            "effectiveHome": home.path,
            "configPath": home.appendingPathComponent("config.toml").path,
            "configExists": fileManager.fileExists(atPath: home.appendingPathComponent("config.toml").path),
            "sessionsPath": home.appendingPathComponent("sessions", isDirectory: true).path,
            "sessionsExists": fileManager.fileExists(atPath: home.appendingPathComponent("sessions", isDirectory: true).path)
        ]
        if let executableURL {
            result["resolvedPath"] = executableURL.path
            result["path"] = executableURL.path
        } else {
            result["resolvedPath"] = NSNull()
            result["path"] = ""
        }
        return result
    }

    static func executable(configuredPath: String) -> URL? {
        let fileManager = FileManager.default
        let explicit = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            let path = expandingPath(explicit)
            return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = NSHomeDirectory()
        var candidates: [String] = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
            "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
            "\(home)/.volta/bin/codex", "\(home)/Library/pnpm/codex",
            "\(home)/.local/share/pnpm/codex"
        ]
        for root in ["\(home)/.nvm/versions/node", "\(home)/.fnm/node-versions", "\(home)/.asdf/installs/nodejs"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted().reversed() {
                candidates.append("\(root)/\(entry)/bin/codex")
                candidates.append("\(root)/\(entry)/installation/bin/codex")
            }
        }
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

    /// Finder-launched apps commonly do not inherit the shell's PATH. Codex
    /// may itself be a Node entrypoint, so include both the selected executable
    /// directory and the usual Node/Homebrew version directories when starting
    /// it. This does not execute a shell or interpolate user input.
    static func childEnvironment(for executable: URL, configuredHome: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["CODEX_HOME"] = effectiveHome(configuredHome: configuredHome, environment: base).path
        var directories = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        let home = NSHomeDirectory()
        for root in ["\(home)/.nvm/versions/node", "\(home)/.fnm/node-versions", "\(home)/.asdf/installs/nodejs"] {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
                directories.append(contentsOf: entries.map { "\(root)/\($0)/bin" })
            }
        }
        if let existing = base["PATH"] { directories.append(contentsOf: existing.split(separator: ":").map(String.init)) }
        var seen = Set<String>()
        environment["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    static func version(at executable: URL, completion: @escaping (String?) -> Void) {
        let process = Process()
        let pipe = Pipe()
        let lock = NSLock()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = childEnvironment(for: executable, configuredHome: AppPreferences.shared.codexHome)
        process.standardOutput = pipe
        process.standardError = pipe
        var completed = false
        func finish(_ value: String?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            DispatchQueue.main.async { completion(value) }
        }
        do { try process.run() } catch { finish(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(value?.isEmpty == false ? value : nil)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            guard process.isRunning else { return }
            process.terminate()
            finish(nil)
        }
    }
}

/// Owns one app-server process. Process I/O, JSONL framing, request correlation,
/// timeouts and process generations stay off the main/UI queue.
final class CodexAppServerClient {
    var onStateChange: ((ProviderState) -> Void)?
    private let preferences: AppPreferences
    private let protocolQueue = DispatchQueue(label: "ai.balance.whale.codex.protocol", qos: .utility)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var frameDecoder = JSONLFrameDecoder()
    private var initialized = false
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var generation = 0
    private var stage = "idle"
    private var stderrTail = ""
    private var refreshInFlight = false
    private var sleeping = false
    private var state = ProviderState()
    private var cache: CachedSnapshot?

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences
        cache = readCache()
    }

    func refresh(requestID: String? = nil) { DispatchQueue.main.async { [weak self] in self?.refreshOnMain(requestID: requestID) } }
    func stop() { DispatchQueue.main.async { [weak self] in self?.stopOnMain() } }
    func stopImmediately() { protocolQueue.async { [weak self] in self?.stopProtocol() } }

    func configurationChanged(requestID: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            stopOnMain()
            refreshInFlight = false
            state.accountKey = nil
            state.email = nil
            state.planType = nil
            state.buckets = []
            state.lastUpdated = nil
            state.cliPath = nil
            state.cliVersion = nil
            state.status = .idle
            state.message = "设置已保存，正在重新连接 Codex…"
            emit()
            refreshOnMain(requestID: requestID)
        }
    }

    func setSleeping(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sleeping = value
            if value { stopOnMain() } else { refreshOnMain() }
        }
    }

    private func refreshOnMain(requestID: String? = nil) {
        guard !sleeping, !refreshInFlight else { return }
        refreshInFlight = true
        state.requestID = requestID
        state.status = .loading
        state.message = "正在从 Codex app-server 查询额度…"
        emit()
        guard let executable = CodexLocator.executable(configuredPath: preferences.codexPath) else {
            let configured = preferences.codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.cliMissing, message: configured.isEmpty ? "请安装 Codex CLI，或在设置中指定 codex 可执行文件路径" : "设置中的 codex 路径不可执行，请重新选择文件或清空后自动探测")
            return
        }
        state.cliPath = executable.path
        state.cliVersion = nil
        CodexLocator.version(at: executable) { [weak self] version in
            guard let self, self.state.cliPath == executable.path else { return }
            self.state.cliVersion = version
            self.emit()
        }
        ensureServer(executable: executable) { [weak self] error in
            guard let self else { return }
            if let error { finish(error, message: error.localizedDescription); return }
            readAccountAndLimits()
        }
    }

    private func ensureServer(executable: URL, completion: @escaping (ProviderError?) -> Void) {
        protocolQueue.async { [weak self] in
            guard let self else { return }
            if self.process?.isRunning == true, self.initialized {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.stopProtocol()
            self.generation += 1
            let currentGeneration = self.generation
            self.stage = "launching"
            let newProcess = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            newProcess.executableURL = executable
            newProcess.arguments = ["app-server", "--listen", "stdio://"]
            let environment = CodexLocator.childEnvironment(for: executable, configuredHome: self.preferences.codexHome)
            newProcess.environment = environment
            newProcess.standardInput = stdin
            newProcess.standardOutput = stdout
            newProcess.standardError = stderr
            do {
                try newProcess.run()
            } catch {
                DispatchQueue.main.async { completion(.launch(error.localizedDescription)) }
                return
            }
            self.process = newProcess
            self.input = stdin.fileHandleForWriting
            self.output = stdout.fileHandleForReading
            self.stderr = stderr.fileHandleForReading
            self.initialized = false
            self.frameDecoder.reset()
            self.stderrTail = ""
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                do {
                    let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                    self.protocolQueue.async {
                        guard self.generation == currentGeneration else { return }
                        if data.isEmpty {
                            self.handleTransportFailure(.processExited(stage: self.stage), generation: currentGeneration)
                        } else {
                            self.consume(data, generation: currentGeneration)
                        }
                    }
                } catch {
                    self.protocolQueue.async {
                        guard self.generation == currentGeneration else { return }
                        self.handleTransportFailure(.offline(self.redact(error.localizedDescription)), generation: currentGeneration)
                    }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return }
                self.protocolQueue.async {
                    guard self.generation == currentGeneration else { return }
                    self.appendStderr(data)
                }
            }
            newProcess.terminationHandler = { [weak self] _ in
                self?.protocolQueue.async {
                    guard let self, self.generation == currentGeneration else { return }
                    self.handleTransportFailure(.processExited(stage: self.stage), generation: currentGeneration)
                }
            }
            self.stage = "initialize"
            self.sendRequestProtocol(
                method: "initialize",
                params: ["clientInfo": ["name": "ai_balance_whale", "title": "AI Balance Whale", "version": "0.1.0"]],
                stage: self.stage,
                generation: currentGeneration
            ) { [weak self] _, error in
                guard let self, self.generation == currentGeneration else { return }
                if let error {
                    DispatchQueue.main.async { completion(error) }
                    return
                }
                self.initialized = true
                self.sendNotificationProtocol(method: "initialized", params: [:])
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func readAccountAndLimits() {
        stageRequest(method: "account/read", params: ["refreshToken": false], stage: "account/read") { [weak self] result, error in
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
            if accountType == "apikey" || accountType == "api_key" {
                finish(.apiKeyUnsupported, message: ProviderError.apiKeyUnsupported.localizedDescription)
                return
            }
            if accountType == "amazonbedrock" || accountType == "personalaccesstoken" {
                let error = ProviderError.unsupported("当前认证模式不提供 ChatGPT 订阅额度")
                finish(error, message: error.localizedDescription)
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
                let cached = self.cache
                self.cache = key.flatMap { cached?.accountKey == $0 ? cached : nil }
            }
            state.email = email
            state.planType = planType
            stageRequest(method: "account/rateLimits/read", params: nil, stage: "account/rateLimits/read") { [weak self] limits, error in
                guard let self else { return }
                if let error { useCacheOrFail(error: error); return }
                guard let limits else {
                    useCacheOrFail(error: .protocolError("account/rateLimits/read 返回空响应"))
                    return
                }
                applyRateLimits(limits, accountKey: key, email: email, planType: planType)
                finishReady()
            }
        }
    }

    private func stageRequest(method: String, params: [String: Any]?, stage: String, completion: @escaping ([String: Any]?, ProviderError?) -> Void) {
        protocolQueue.async { [weak self] in
            guard let self else { return }
            let currentGeneration = self.generation
            self.stage = stage
            self.sendRequestProtocol(method: method, params: params, stage: stage, generation: currentGeneration) { result, error in
                DispatchQueue.main.async { completion(result, error) }
            }
        }
    }

    private func sendRequestProtocol(method: String, params: [String: Any]?, stage: String, generation: Int, completion: @escaping ([String: Any]?, ProviderError?) -> Void) {
        guard self.generation == generation else { return }
        let id = nextRequestID
        nextRequestID += 1
        let timeoutSeconds = 15
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, let request = self.pending.removeValue(forKey: id) else { return }
            request.completion(nil, .timeout(stage: stage, seconds: timeoutSeconds))
            self.stopProtocol()
        }
        pending[id] = PendingRequest(completion: completion, timeout: timeout)
        protocolQueue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeout)
        writeMessageProtocol(["method": method, "id": id, "params": params ?? [:]], generation: generation)
    }

    private func sendNotificationProtocol(method: String, params: [String: Any]) {
        writeMessageProtocol(["method": method, "params": params], generation: generation)
    }

    private func consume(_ data: Data, generation: Int) {
        guard self.generation == generation else { return }
        for frame in frameDecoder.append(data) {
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                appendDiagnostic("invalid JSONL frame")
                continue
            }
            if let id = int(object["id"]), let request = pending.removeValue(forKey: id) {
                request.timeout.cancel()
                request.completion(object["result"] as? [String: Any], parseError(object["error"]))
            } else if object["id"] == nil {
                handleNotification(object)
            }
        }
    }

    private func writeMessageProtocol(_ object: [String: Any], generation: Int) {
        guard self.generation == generation,
              let input,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do {
            try input.write(contentsOf: data)
            try input.write(contentsOf: Data([10]))
        } catch {
            handleTransportFailure(.offline(redact(error.localizedDescription)), generation: generation)
        }
    }

    private func handleNotification(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        switch method {
        case "account/rateLimits/updated":
            let parsed = RateLimitParser.parse(message)
            guard !parsed.buckets.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.accountKey != nil else { return }
                self.state.buckets = parsed.buckets
                self.state.lastUpdated = Date()
                if self.state.status != .ready {
                    self.state.status = .ready
                    self.state.message = "额度已由 Codex 更新"
                }
                if let cache = self.cache, let key = self.state.accountKey {
                    self.cache = CachedSnapshot(accountKey: key, email: cache.email, planType: cache.planType, buckets: parsed.buckets, lastUpdated: Date())
                    self.writeCache(self.cache)
                }
                self.emit()
            }
        case "account/updated":
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.refreshInFlight else { return }
                self.state.buckets = []
                self.state.lastUpdated = nil
                self.refreshOnMain(requestID: self.state.requestID)
            }
        default:
            break
        }
    }

    private func parseError(_ object: Any?) -> ProviderError? {
        guard let object = object as? [String: Any] else { return nil }
        let message = object["message"] as? String ?? "Codex app-server 返回未知错误"
        let code = int(object["code"]).map { " (错误码 \($0))" } ?? ""
        let lower = message.lowercased()
        if lower.contains("unauthorized") || lower.contains("not logged") || lower.contains("authentication") {
            return .notLoggedIn
        }
        return .serverError("Codex app-server：\(message)\(code)")
    }

    private func handleTransportFailure(_ error: ProviderError, generation: Int) {
        guard self.generation == generation else { return }
        let finalError: ProviderError
        if case .processExited = error, !stderrTail.isEmpty {
            finalError = .offline("\(error.localizedDescription)；stderr：\(stderrTail)")
        } else {
            finalError = error
        }
        stopProtocol()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.refreshInFlight || self.state.status == .ready {
                self.useCacheOrFail(error: finalError)
            }
        }
    }

    private func stopOnMain() { protocolQueue.async { [weak self] in self?.stopProtocol() } }

    private func stopProtocol() {
        generation += 1
        output?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        input = nil
        output = nil
        stderr = nil
        initialized = false
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        frameDecoder.reset()
        for request in pending.values { request.timeout.cancel() }
        pending.removeAll()
        stage = "idle"
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

    private func accountKey(_ account: [String: Any]) -> String? {
        for key in ["id", "accountId", "chatgptAccountId", "email"] {
            if let value = account[key] as? String, !value.isEmpty { return value }
        }
        // Account type is not an identity; never use it as a cache key.
        return nil
    }

    private func appendStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrTail = String((stderrTail + redact(text)).suffix(1200))
    }

    private func appendDiagnostic(_ text: String) {
        stderrTail = String((stderrTail + " " + text).suffix(1200))
    }

    private func redact(_ text: String) -> String {
        var result = text
        for marker in ["Authorization:", "authorization:", "access_token", "refresh_token", "id_token"] {
            if let range = result.range(of: marker) {
                result = String(result[..<range.upperBound]) + " <redacted>"
            }
        }
        return result.replacingOccurrences(of: "\n", with: " ")
    }

    private func emit() { onStateChange?(state) }

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Balance Whale", isDirectory: true)
            .appendingPathComponent("codex-rate-limit.json")
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
