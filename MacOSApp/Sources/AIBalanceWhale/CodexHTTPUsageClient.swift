import Foundation
import CodexCore

/// Read-only adapter for the same WHAM usage endpoint used by the open-source
/// Codex client. Tokens remain in this native object; no credential enters a WebView.
final class CodexHTTPUsageClient {
    var onStateChange: ((ProviderState) -> Void)?
    private let preferences: AppPreferences
    private let queue = DispatchQueue(label: "ai.balance.whale.codex.http", qos: .utility)
    private var state = ProviderState()
    private var task: URLSessionDataTask?
    private var sleeping = false
    private var generation = 0

    init(preferences: AppPreferences = .shared) { self.preferences = preferences }
    func refresh(requestID: String? = nil) { queue.async { [weak self] in self?.refreshLocked(requestID: requestID) } }
    func configurationChanged(requestID: String? = nil) { queue.async { [weak self] in self?.task?.cancel(); self?.state = ProviderState(); self?.refreshLocked(requestID: requestID) } }
    func setSleeping(_ value: Bool) { queue.async { [weak self] in self?.sleeping = value; if value { self?.task?.cancel() } else { self?.refreshLocked() } } }
    func stopImmediately() { queue.async { [weak self] in self?.task?.cancel(); self?.task = nil } }

    private func refreshLocked(requestID: String? = nil) {
        guard !sleeping else { return }
        task?.cancel(); generation += 1
        let requestGeneration = generation
        state.status = .loading; state.message = "Reading local Codex login and usage..."; state.requestID = requestID; emit()
        switch LocalCodexCredential.load(home: CodexLocator.effectiveHome(configuredHome: preferences.codexHome)) {
        case .failure(let error): finish(error, generation: requestGeneration)
        case .success(let credential): requestUsage(credential, generation: requestGeneration, retried: false)
        }
    }

    private func requestUsage(_ credential: LocalCodexCredential, generation: Int, retried: Bool) {
        guard generation == self.generation, let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("AI-Balance-Whale/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async {
                guard let self, generation == self.generation else { return }
                if let error { self.finish(.offline(error.localizedDescription), generation: generation); return }
                guard let http = response as? HTTPURLResponse else { self.finish(.offline("No HTTP response"), generation: generation); return }
                if http.statusCode == 401, !retried {
                    switch LocalCodexCredential.load(home: CodexLocator.effectiveHome(configuredHome: self.preferences.codexHome)) {
                    case .success(let current): self.requestUsage(current, generation: generation, retried: true)
                    case .failure(let error): self.finish(error, generation: generation)
                    }; return
                }
                guard (200...299).contains(http.statusCode) else {
                    let message: String
                    switch http.statusCode { case 401: message = "Codex login expired; sign in again then refresh"; case 403: message = "This ChatGPT account cannot read subscription usage"; case 429: message = "Usage service rate limited the request"; default: message = "Usage service returned HTTP \(http.statusCode)" }
                    self.finish(.serverError(message), generation: generation); return
                }
                guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.finish(.protocolError("Usage service returned non-JSON data"), generation: generation); return }
                let parsed = WhamUsageParser.parse(object)
                self.state.status = .ready
                self.state.message = parsed.buckets.isEmpty ? "Connected, but the service returned no usable windows" : "Usage read through local Codex login"
                self.state.accountKey = credential.accountID; self.state.email = credential.email; self.state.planType = parsed.planType
                self.state.buckets = parsed.buckets; self.state.lastUpdated = parsed.parsedAt
                self.state.cliPath = CodexLocator.executable(configuredPath: self.preferences.codexPath)?.path; self.state.authSource = credential.source
                self.emit()
            }
        }; task?.resume()
    }
    private func finish(_ error: ProviderError, generation: Int) { guard generation == self.generation else { return }; state.status = status(for: error); state.message = error.localizedDescription; state.buckets = []; state.lastUpdated = nil; emit() }
    private func status(for error: ProviderError) -> ProviderStatus { switch error { case .notLoggedIn: return .notLoggedIn; case .apiKeyUnsupported: return .apiKeyUnsupported; case .offline: return .offline; default: return .error } }
    private func emit() { let value = state; DispatchQueue.main.async { [weak self] in self?.onStateChange?(value) } }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct LocalCodexCredential {
    let accessToken: String; let accountID: String; let email: String?; let source: String
    static func load(home: URL) -> Result<LocalCodexCredential, ProviderError> {
        let url = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.notLoggedIn) }
        let mode = (root["auth_mode"] as? String ?? "").lowercased()
        let configuredAPIKey = (root["OPENAI_API_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard mode != "apikey" && configuredAPIKey.isEmpty else { return .failure(.apiKeyUnsupported) }
        guard let tokens = root["tokens"] as? [String: Any], let access = tokens["access_token"] as? String, !access.isEmpty else { return .failure(.notLoggedIn) }
        let claims = jwtClaims(tokens["id_token"] as? String), auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        guard let account = (tokens["account_id"] as? String) ?? (auth?["chatgpt_account_id"] as? String), !account.isEmpty else { return .failure(.notLoggedIn) }
        return .success(LocalCodexCredential(accessToken: access, accountID: account, email: claims?["email"] as? String, source: "CODEX_HOME/auth.json"))
    }
    private static func jwtClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }; let pieces = token.split(separator: "."); guard pieces.count > 1 else { return nil }
        var body = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body) else { return nil }; return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
