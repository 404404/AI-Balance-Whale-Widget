import Foundation
import CodexCore

/// Native HTTP adapter for the official ChatGPT WHAM usage endpoint. It uses
/// only the App-owned Keychain credential and never launches Codex CLI.
final class CodexHTTPUsageClient {
    var onStateChange: ((ProviderState) -> Void)?
    private let store: CodexCredentialStore
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.codex.http", qos: .utility)
    private var state = ProviderState()
    private var task: URLSessionDataTask?
    private var sleeping = false
    private var generation = 0

    init(store: CodexCredentialStore = .shared) { self.store = store }
    func refresh(requestID: String? = nil) { queue.async { [weak self] in self?.refreshLocked(requestID: requestID) } }
    func configurationChanged(requestID: String? = nil) { queue.async { [weak self] in self?.task?.cancel(); self?.generation += 1; self?.refreshLocked(requestID: requestID) } }
    func setSleeping(_ value: Bool) { queue.async { [weak self] in self?.sleeping = value; if value { self?.task?.cancel() } else { self?.refreshLocked() } } }
    func stopImmediately() { queue.async { [weak self] in self?.generation += 1; self?.task?.cancel(); self?.task = nil } }

    private func refreshLocked(requestID: String? = nil) {
        guard !sleeping else { return }
        task?.cancel(); generation += 1
        let requestGeneration = generation
        state = ProviderState(status: .loading, message: "正在读取 App 登录的 Codex 额度…", requestID: requestID)
        emit()
        store.accessToken { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard requestGeneration == self.generation, !self.sleeping else { return }
                switch result {
                case .success(let credential): self.requestUsage(credential, generation: requestGeneration, requestID: requestID, retried: false)
                case .failure(let error): self.finish(error, generation: requestGeneration, requestID: requestID)
                }
            }
        }
    }

    private func requestUsage(_ credential: CodexCredentialStore.Credential, generation: Int, requestID: String?, retried: Bool) {
        guard generation == self.generation, let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("AI-Balance-Whale/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, !self.sleeping else { return }
                if let error { self.finish(.offline(error.localizedDescription), generation: generation, requestID: requestID); return }
                guard let http = response as? HTTPURLResponse else { self.finish(.offline("额度服务没有返回 HTTP 响应"), generation: generation, requestID: requestID); return }
                if http.statusCode == 401 && !retried {
                    self.store.accessToken(forceRefresh: true) { [weak self] result in
                        guard let self else { return }
                        self.queue.async {
                            guard generation == self.generation else { return }
                            switch result {
                            case .success(let current): self.requestUsage(current, generation: generation, requestID: requestID, retried: true)
                            case .failure(let error): self.finish(error, generation: generation, requestID: requestID)
                            }
                        }
                    }
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    let error: ProviderError
                    switch http.statusCode {
                    case 401: error = .notLoggedIn
                    case 403: error = .serverError("当前 ChatGPT 账户已登录，但无权读取订阅额度")
                    case 429: error = .serverError("额度服务暂时限流，请稍后刷新")
                    default: error = .serverError("额度服务返回 HTTP \(http.statusCode)")
                    }
                    self.finish(error, generation: generation, requestID: requestID); return
                }
                guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.finish(.protocolError("额度服务返回的不是 JSON"), generation: generation, requestID: requestID); return }
                let parsed = WhamUsageParser.parse(object)
                self.state = ProviderState(status: parsed.buckets.isEmpty ? .unsupported : .ready, message: parsed.buckets.isEmpty ? "账号已登录，但额度服务没有可用窗口" : "Codex 订阅额度已更新", email: credential.email, planType: parsed.planType, accountKey: credential.accountID, buckets: parsed.buckets, lastUpdated: parsed.parsedAt, authSource: credential.source, requestID: requestID)
                self.emit()
            }
        }
        task?.resume()
    }

    private func finish(_ error: ProviderError, generation: Int, requestID: String?) {
        guard generation == self.generation else { return }
        state = ProviderState(status: status(for: error), message: error.localizedDescription, email: state.email, planType: state.planType, accountKey: state.accountKey, authSource: "app-keychain", requestID: requestID)
        emit()
    }

    private func status(for error: ProviderError) -> ProviderStatus {
        switch error { case .notLoggedIn: return .notLoggedIn; case .apiKeyUnsupported: return .apiKeyUnsupported; case .offline: return .offline; case .unsupported: return .unsupported; default: return .error }
    }
    private func emit() { let value = state; DispatchQueue.main.async { [weak self] in self?.onStateChange?(value) } }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
