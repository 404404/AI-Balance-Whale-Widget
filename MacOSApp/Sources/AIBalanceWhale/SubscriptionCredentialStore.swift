import Foundation
import Security
import CodexCore

/// App-owned Grok / Cursor credentials. Tokens stay in Keychain and never
/// enter WebView payloads, configuration backups, or diagnostics.
final class SubscriptionCredentialStore {
    static let grok = SubscriptionCredentialStore(provider: "grok")
    static let cursor = SubscriptionCredentialStore(provider: "cursor")

    struct Credential: Codable {
        var accountID: String
        var email: String?
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var source: String
    }

    private let provider: String
    private let service: String
    private let accountKey = "active"
    private let queue: DispatchQueue
    private var refreshTask: URLSessionDataTask?
    private var refreshWaiters: [(Result<Credential, ProviderError>) -> Void] = []

    private init(provider: String) {
        self.provider = provider
        self.service = "com.404404.AIBalanceWhale.\(provider)-auth"
        self.queue = DispatchQueue(label: "com.404404.AIBalanceWhale.\(provider)-keychain")
    }

    static func store(for provider: String) -> SubscriptionCredentialStore? {
        switch provider {
        case "grok": return grok
        case "cursor": return cursor
        default: return nil
        }
    }

    func save(accessToken: String, refreshToken: String?, accountID: String, email: String?, expiresIn: Int?, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let old = self.readLocked()
            let value = Credential(
                accountID: accountID,
                email: email ?? old?.email,
                accessToken: accessToken,
                refreshToken: refreshToken ?? old?.refreshToken,
                expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                source: "app-keychain"
            )
            let ok = self.writeLocked(value)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    func statusPayload() -> [String: Any] {
        queue.sync {
            guard let credential = readLocked() else {
                return ["status": "notLoggedIn", "authSource": "app-keychain", "provider": provider]
            }
            var payload: [String: Any] = [
                "status": "ready",
                "authSource": credential.source,
                "accountID": credential.accountID,
                "provider": provider,
            ]
            if let email = credential.email { payload["email"] = email }
            return payload
        }
    }

    func hasCredential() -> Bool {
        queue.sync { readLocked() != nil }
    }

    func accessToken(forceRefresh: Bool = false, completion: @escaping (Result<Credential, ProviderError>) -> Void) {
        queue.async {
            guard let credential = self.readLocked() else {
                DispatchQueue.main.async { completion(.failure(.notLoggedIn)) }
                return
            }
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
        let session = URLSession(configuration: .ephemeral, delegate: HTTPNoRedirectDelegate(), delegateQueue: nil)
        if provider == "grok" {
            guard let url = URL(string: GrokOAuthSupport.issuer + GrokOAuthSupport.tokenPath) else {
                finishRefreshLocked(.failure(.protocolError("token endpoint unavailable")))
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let fields = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": GrokOAuthSupport.clientID]
            request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)
            refreshTask = session.dataTask(with: request) { [weak self] data, response, error in
                self?.finishHTTPRefresh(credential: credential, data: data, response: response, error: error, accessKey: "access_token", refreshKey: "refresh_token")
            }
            refreshTask?.resume()
            return
        }
        guard let url = URL(string: CursorOAuthSupport.refreshURL) else {
            finishRefreshLocked(.failure(.protocolError("token endpoint unavailable")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        refreshTask = session.dataTask(with: request) { [weak self] data, response, error in
            self?.finishHTTPRefresh(credential: credential, data: data, response: response, error: error, accessKey: "accessToken", refreshKey: "refreshToken")
        }
        refreshTask?.resume()
    }

    private func finishHTTPRefresh(credential: Credential, data: Data?, response: URLResponse?, error: Error?, accessKey: String, refreshKey: String) {
        queue.async {
            self.refreshTask = nil
            if let error { self.finishRefreshLocked(.failure(.offline(error.localizedDescription))); return }
            guard let http = response as? HTTPURLResponse else {
                self.finishRefreshLocked(.failure(.offline("token endpoint returned no HTTP response")))
                return
            }
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let access = (object?[accessKey] as? String) ?? (object?["access_token"] as? String)
            guard (200...299).contains(http.statusCode), let access, !access.isEmpty else {
                let error: ProviderError = http.statusCode == 401 ? .notLoggedIn : .serverError("授权刷新返回 HTTP \(http.statusCode)")
                self.finishRefreshLocked(.failure(error))
                return
            }
            let updated = Credential(
                accountID: credential.accountID,
                email: credential.email,
                accessToken: access,
                refreshToken: (object?[refreshKey] as? String) ?? (object?["refresh_token"] as? String) ?? credential.refreshToken,
                expiresAt: (object?["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) },
                source: credential.source
            )
            guard self.writeLocked(updated) else {
                self.finishRefreshLocked(.failure(.serverError("无法保存授权凭据")))
                return
            }
            self.finishRefreshLocked(.success(updated))
        }
    }

    private func finishRefreshLocked(_ result: Result<Credential, ProviderError>) {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { waiter in DispatchQueue.main.async { waiter(result) } }
    }

    private func readLocked() -> Credential? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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
