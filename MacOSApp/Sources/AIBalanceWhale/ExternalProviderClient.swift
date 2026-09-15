import Foundation

struct ExternalBalance {
    let id: String
    let name: String
    let currency: String
    let status: String
    let message: String
    let remaining: Double?
    let total: Double?
    let used: Double?
    let updatedAt: Date?

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "id": id, "name": name, "currency": currency,
            "status": status, "message": message
        ]
        if let remaining { result["remaining"] = remaining }
        if let total { result["total"] = total }
        if let used { result["used"] = used }
        if let updatedAt { result["updatedAt"] = updatedAt.timeIntervalSince1970 * 1000 }
        return result
    }
}

final class ExternalProviderClient {
    var onUpdate: (([[String: Any]]) -> Void)?
    private let session: URLSession
    private var tasks: [URLSessionDataTask] = []
    private var generation = 0

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func refresh() {
        generation += 1
        let currentGeneration = generation
        tasks.forEach { $0.cancel() }
        tasks.removeAll()

        let providers = (WhaleConfigurationStore.shared.snapshot()["providers"] as? [[String: Any]] ?? [])
            .filter { ($0["enabled"] as? Bool) != false }
            .filter { (($0["kind"] as? String) ?? "") != "codex" }
        guard !providers.isEmpty else {
            onUpdate?([])
            return
        }

        var results = providers.map { provider in
            ExternalBalance(
                id: provider["id"] as? String ?? UUID().uuidString,
                name: provider["name"] as? String ?? "厂商",
                currency: provider["currency"] as? String ?? "",
                status: "unavailable",
                message: "尚未配置余额接口",
                remaining: nil, total: nil, used: nil, updatedAt: nil
            )
        }
        publish(results, generation: currentGeneration)

        for (index, provider) in providers.enumerated() {
            guard let urlString = requestURL(provider: provider),
                  let url = URL(string: urlString),
                  let keyRef = provider["keyRef"] as? String,
                  let key = WhaleConfigurationStore.shared.credential(reference: keyRef),
                  !key.isEmpty else {
                continue
            }
            guard provider["noBalanceApi"] as? Bool != true else {
                results[index] = ExternalBalance(
                    id: results[index].id, name: results[index].name,
                    currency: results[index].currency, status: "unsupported",
                    message: provider["note"] as? String ?? "该厂商没有公开余额接口",
                    remaining: nil, total: nil, used: nil, updatedAt: nil
                )
                publish(results, generation: currentGeneration)
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(authHeader(provider: provider, key: key), forHTTPHeaderField: "Authorization")
            if let headers = provider["headers"] as? [String: String] {
                headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            }
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGeneration else { return }
                    let old = results[index]
                    if let error {
                        results[index] = ExternalBalance(id: old.id, name: old.name, currency: old.currency, status: "error", message: "接口请求失败：\(error.localizedDescription)", remaining: nil, total: nil, used: nil, updatedAt: nil)
                    } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        results[index] = ExternalBalance(id: old.id, name: old.name, currency: old.currency, status: "error", message: "接口返回 HTTP \(http.statusCode)", remaining: nil, total: nil, used: nil, updatedAt: nil)
                    } else if let data, let object = try? JSONSerialization.jsonObject(with: data) {
                        results[index] = self.parse(provider: provider, object: object, fallback: old)
                    } else {
                        results[index] = ExternalBalance(id: old.id, name: old.name, currency: old.currency, status: "error", message: "接口返回不是有效 JSON", remaining: nil, total: nil, used: nil, updatedAt: nil)
                    }
                    self.publish(results, generation: currentGeneration)
                }
            }
            tasks.append(task)
            task.resume()
        }
    }

    private func publish(_ results: [ExternalBalance], generation: Int) {
        guard generation == self.generation else { return }
        onUpdate?(results.map { $0.dictionary })
    }

    private func requestURL(provider: [String: Any]) -> String? {
        guard var value = provider["balanceURL"] as? String, !value.isEmpty else { return nil }
        if value.contains("{base}") {
            guard let base = provider["baseURL"] as? String, !base.isEmpty else { return nil }
            value = value.replacingOccurrences(of: "{base}", with: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return value
    }

    private func authHeader(provider: [String: Any], key: String) -> String {
        (provider["auth"] as? String ?? "Bearer {key}").replacingOccurrences(of: "{key}", with: key)
    }

    private func parse(provider: [String: Any], object: Any, fallback: ExternalBalance) -> ExternalBalance {
        let scale = (provider["scale"] as? NSNumber)?.doubleValue ?? 1
        let valuePath = provider["valuePath"] as? String ?? ""
        let totalPath = provider["totalPath"] as? String ?? ""
        let usedPath = provider["usedPath"] as? String ?? ""
        let value = number(at: valuePath, in: object).map { $0 * scale }
        let total = number(at: totalPath, in: object).map { $0 * scale }
        let used = number(at: usedPath, in: object).map { $0 * scale }
        if value == nil && total == nil && used == nil {
            return ExternalBalance(id: fallback.id, name: fallback.name, currency: fallback.currency, status: "error", message: "找不到配置的字段路径", remaining: nil, total: nil, used: nil, updatedAt: nil)
        }
        let remaining: Double?
        if let value { remaining = value }
        else if let total, let used { remaining = max(0, total - used) }
        else { remaining = nil }
        let calculatedUsed = used ?? (total.flatMap { total in remaining.map { max(0, total - $0) } })
        return ExternalBalance(id: fallback.id, name: fallback.name, currency: fallback.currency, status: "ready", message: "接口余额已更新", remaining: remaining, total: total, used: calculatedUsed, updatedAt: Date())
    }

    private func number(at path: String, in object: Any) -> Double? {
        guard !path.isEmpty else { return nil }
        var current: Any = object
        for component in path.split(separator: ".").map(String.init) {
            var name = component
            var indexes: [Int] = []
            while let open = name.firstIndex(of: "["), let close = name.firstIndex(of: "]"), close > open {
                let raw = String(name[name.index(after: open)..<close])
                if let index = Int(raw) { indexes.append(index) }
                name.removeSubrange(open...close)
            }
            if !name.isEmpty {
                guard let dictionary = current as? [String: Any], let next = dictionary[name] else { return nil }
                current = next
            }
            for index in indexes {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        if let number = current as? NSNumber { return number.doubleValue }
        if let string = current as? String { return Double(string) }
        return nil
    }
}
