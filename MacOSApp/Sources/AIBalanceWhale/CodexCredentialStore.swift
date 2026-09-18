import Foundation
import Security
import CodexCore

/// App-owned Codex credential store. Secrets are kept in Keychain and are
/// never included in WebView payloads, configuration backups or diagnostics.
final class CodexCredentialStore {
    static let shared = CodexCredentialStore()
    private let service = "com.404404.AIBalanceWhale.codex-auth"
    private let accountKey = "active"
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.codex-keychain")
    private var refreshTask: URLSessionDataTask?
    private var refreshWaiters: [(Result<Credential, ProviderError>) -> Void] = []

    struct Credential: Codable {
        var accountID: String
        var email: String?
        var planType: String?
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var source: String
    }

    private init() {}

    func save(accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Int?, accountID: String?, email: String?, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let claims = idToken.flatMap(CodexOAuthSupport.parseJWTClaims)
            let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
            let accessClaims = CodexOAuthSupport.parseJWTClaims(accessToken)
            let accessAuth = accessClaims?["https://api.openai.com/auth"] as? [String: Any]
            let resolvedAccount = accountID
                ?? (claims?["chatgpt_account_id"] as? String)
                ?? (auth?["chatgpt_account_id"] as? String)
                ?? (accessClaims?["chatgpt_account_id"] as? String)
                ?? (accessAuth?["chatgpt_account_id"] as? String)
            guard let resolvedAccount, !resolvedAccount.isEmpty else { DispatchQueue.main.async { completion?(false) }; return }
            let old = self.readLocked()
            let plan = (auth?["chatgpt_plan_type"] as? String) ?? (claims?["plan_type"] as? String)
            let displayEmail = email ?? (claims?["email"] as? String) ?? (accessClaims?["email"] as? String)
            let value = Credential(accountID: resolvedAccount, email: displayEmail, planType: plan, accessToken: accessToken, refreshToken: refreshToken ?? old?.refreshToken, expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }, source: "app-keychain")
            let ok = self.writeLocked(value)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    func statusPayload() -> [String: Any] {
        queue.sync {
            guard let credential = readLocked() else { return ["status": "notLoggedIn", "authSource": "app-keychain"] }
            var payload: [String: Any] = ["status": "ready", "authSource": credential.source, "accountID": credential.accountID]
            if let email = credential.email { payload["email"] = email }
            if let plan = credential.planType { payload["plan"] = plan }
            return payload
        }
    }

    func accessToken(forceRefresh: Bool = false, completion: @escaping (Result<Credential, ProviderError>) -> Void) {
        queue.async {
            guard let credential = self.readLocked() else { DispatchQueue.main.async { completion(.failure(.notLoggedIn)) }; return }
            let valid = !forceRefresh && (credential.expiresAt == nil || credential.expiresAt!.timeIntervalSinceNow > 60)
            if valid { DispatchQueue.main.async { completion(.success(credential)) }; return }
            guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
                DispatchQueue.main.async { completion(.failure(.notLoggedIn)) }
                return
            }
            self.refreshWaiters.append(completion)
            if self.refreshTask == nil { self.startRefreshLocked(credential: credential, refreshToken: refreshToken) }
        }
    }

    func disconnect(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            self.refreshTask?.cancel()
            self.refreshTask = nil
            self.refreshWaiters.removeAll()
            let ok = self.deleteLocked()
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    private func startRefreshLocked(credential: Credential, refreshToken: String) {
        guard let url = URL(string: CodexOAuthSupport.issuer + "/oauth/token") else { finishRefreshLocked(.failure(.protocolError("token endpoint unavailable"))); return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": CodexOAuthSupport.clientID]
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        refreshTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.refreshTask = nil
                if let error { self.finishRefreshLocked(.failure(.offline(error.localizedDescription))); return }
                guard let http = response as? HTTPURLResponse else { self.finishRefreshLocked(.failure(.offline("token endpoint returned no HTTP response"))); return }
                guard (200...299).contains(http.statusCode), let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["access_token"] as? String, !access.isEmpty else {
                    let error: ProviderError = http.statusCode == 401 ? .notLoggedIn : .serverError("授权刷新返回 HTTP \(http.statusCode)")
                    self.finishRefreshLocked(.failure(error)); return
                }
                let updated = Credential(accountID: credential.accountID, email: credential.email, planType: credential.planType, accessToken: access, refreshToken: (object["refresh_token"] as? String) ?? credential.refreshToken, expiresAt: (object["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }, source: credential.source)
                guard self.writeLocked(updated) else { self.finishRefreshLocked(.failure(.serverError("无法保存授权凭据"))); return }
                self.finishRefreshLocked(.success(updated))
            }
        }
        refreshTask?.resume()
    }

    private func finishRefreshLocked(_ result: Result<Credential, ProviderError>) {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { waiter in DispatchQueue.main.async { waiter(result) } }
    }

    private func readLocked() -> Credential? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountKey, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    private func writeLocked(_ credential: Credential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountKey]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess }
        return status == errSecSuccess
    }

    private func deleteLocked() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountKey]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
