import Foundation
import CodexCore

final class ExternalProviderClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func fetch(provider: String, token: String, completion: @escaping (QuotaFetchSnapshot) -> Void) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(QuotaFetchSnapshot(ok: false, message: "没有填写登录态或密钥"))
            return
        }
        if provider == "cursor" {
            fetchCursor(token: trimmed, completion: completion)
            return
        }
        guard let request = request(provider: provider, token: trimmed) else {
            completion(QuotaFetchSnapshot(ok: false, message: "未知厂商"))
            return
        }
        session.dataTask(with: request) { data, response, error in
            let finish: (QuotaFetchSnapshot) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                finish(QuotaFetchSnapshot(ok: false, message: String(error.localizedDescription.prefix(160))))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                finish(QuotaFetchSnapshot(ok: false, message: "\(label(provider)) HTTP \(status)"))
                return
            }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) else {
                finish(QuotaFetchSnapshot(ok: false, message: "接口返回不是有效 JSON"))
                return
            }
            finish(QuotaJSONParser.parse(provider: provider, object: object))
        }.resume()
    }

    private func fetchCursor(token: String, completion: @escaping (QuotaFetchSnapshot) -> Void) {
        guard let request = request(provider: "cursor", token: token) else {
            completion(QuotaFetchSnapshot(ok: false, message: "Cursor HTTP 请求无效"))
            return
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(QuotaFetchSnapshot(ok: false, message: String(error.localizedDescription.prefix(160)))) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                self.fetchCursorSummary(token: token) { summary in
                    self.fetchCursorSand(token: token) { sand in
                        DispatchQueue.main.async { completion(QuotaJSONParser.mergingCursorBot(summary, sand: sand)) }
                    }
                }
                return
            }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) else {
                self.fetchCursorSummary(token: token) { summary in
                    self.fetchCursorSand(token: token) { sand in
                        DispatchQueue.main.async { completion(QuotaJSONParser.mergingCursorBot(summary, sand: sand)) }
                    }
                }
                return
            }
            let snapshot = QuotaJSONParser.parseCursor(object)
            self.fetchCursorSand(token: token) { sand in
                DispatchQueue.main.async { completion(QuotaJSONParser.mergingCursorBot(snapshot, sand: sand)) }
            }
        }.resume()
    }

    private func fetchCursorSummary(token: String, completion: @escaping (QuotaFetchSnapshot) -> Void) {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            completion(QuotaFetchSnapshot(ok: false, message: "Cursor HTTP 请求无效"))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCursorHeaders(&request, token: token)
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(QuotaFetchSnapshot(ok: false, message: String(error.localizedDescription.prefix(160))))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                completion(QuotaFetchSnapshot(ok: false, message: "Cursor HTTP \(status)"))
                return
            }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) else {
                completion(QuotaFetchSnapshot(ok: false, message: "Cursor 用量无法解析"))
                return
            }
            completion(QuotaJSONParser.parseCursor(object))
        }.resume()
    }

    private func fetchCursorSand(token: String, completion: @escaping (Any?) -> Void) {
        guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCursorHeaders(&request, token: token)
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(nil)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status), let data, let object = try? JSONSerialization.jsonObject(with: data) else {
                completion(nil)
                return
            }
            completion(object)
        }.resume()
    }

    private func request(provider: String, token: String) -> URLRequest? {
        switch provider {
        case "deepseek":
            return get("https://api.deepseek.com/user/balance", headers: ["Authorization": "Bearer \(token)"])
        case "openrouter":
            return get("https://openrouter.ai/api/v1/credits", headers: ["Authorization": "Bearer \(token)"])
        case "codex":
            var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
            headers["Cookie"] = token.contains("=") ? token : "session_token=\(token)"
            return get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        case "grok":
            return get("https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "x-xai-token-auth": "xai-grok-cli",
            ])
        case "cursor":
            guard let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyCursorHeaders(&request, token: token)
            return request
        case "glm":
            return get("https://open.bigmodel.cn/api/monitor/usage/quota/limit", headers: ["Authorization": token])
        case "kimi":
            return get("https://api.kimi.com/coding/v1/usages", headers: ["Authorization": "Bearer \(token)"])
        case "minimax":
            return get("https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains", headers: ["Authorization": "Bearer \(token)"])
        default:
            return nil
        }
    }

    private func get(_ urlString: String, headers: [String: String]) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private func applyCursorHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        if token.hasPrefix("crsr_") || token.hasPrefix("eyJ") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(token.contains("WorkosCursorSessionToken") ? token : "WorkosCursorSessionToken=\(token)", forHTTPHeaderField: "Cookie")
        }
    }
}

private func label(_ provider: String) -> String {
    AccountCatalog.providerMeta[provider]?["label"] ?? provider
}
