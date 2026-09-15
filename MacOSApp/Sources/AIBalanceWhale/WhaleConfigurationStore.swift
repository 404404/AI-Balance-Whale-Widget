import Foundation
import Security

final class WhaleConfigurationStore {
    static let shared = WhaleConfigurationStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.configuration")
    private var object: [String: Any]

    private var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Balance Whale", isDirectory: true)
    }

    private var configurationURL: URL { supportDirectory.appendingPathComponent("configuration.json") }
    private var backupURL: URL { supportDirectory.appendingPathComponent("configuration.backup.json") }
    private var resourceDirectory: URL { supportDirectory.appendingPathComponent("resources", isDirectory: true) }

    private init() {
        object = Self.defaultObject()
        object = loadAndMigrate()
    }

    func snapshot() -> [String: Any] { queue.sync { object } }

    func save(_ incoming: [String: Any]) {
        queue.sync {
            var next = Self.defaultObject()
            Self.merge(&next, incoming)
            next["schemaVersion"] = 2
            object = next
            write(next, to: configurationURL)
        }
    }

    func savePatch(_ patch: [String: Any]) {
        var next = snapshot()
        Self.merge(&next, patch)
        save(next)
    }

    func resetLayout() {
        var next = snapshot()
        next["layout"] = Self.defaultObject()["layout"] as? [String: Any] ?? [:]
        save(next)
    }

    func backupConfiguration() -> URL? {
        queue.sync {
            try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            try? data.write(to: backupURL, options: .atomic)
            return backupURL
        }
    }

    func importConfiguration(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let incoming = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        save(incoming)
        return true
    }

    func resourceDataURL(kind: String, id: String) -> String? {
        queue.sync {
            let entry = resources(kind: kind).first { ($0["id"] as? String) == id }
            guard let relative = entry?["relativePath"] as? String else { return nil }
            let url: URL
            if entry?["builtin"] as? Bool == true {
                guard let base = Bundle.main.resourceURL else { return nil }
                let bundled = base.appendingPathComponent(relative)
                url = bundled
            } else {
                url = resourceDirectory.appendingPathComponent(relative)
            }
            guard let data = try? Data(contentsOf: url), let mime = mimeType(for: url.pathExtension) else { return nil }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
    }

    func importResource(kind: String, name: String, base64: String) -> [String: Any]? {
        guard ["roles", "bubbles", "audio"].contains(kind),
              let data = Data(base64Encoded: base64), data.count <= 20 * 1024 * 1024 else { return nil }
        let ext = sanitizedExtension(name: name, kind: kind)
        guard let mime = mimeType(for: ext) else { return nil }
        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).\(ext)"
        let kindDirectory = resourceDirectory.appendingPathComponent(kind, isDirectory: true)
        let url = kindDirectory.appendingPathComponent(fileName)
        queue.sync {
            try? fileManager.createDirectory(at: kindDirectory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            var list = resources(kind: kind)
            let entry: [String: Any] = ["id": id, "name": name, "relativePath": "\(kind)/\(fileName)", "mime": mime, "builtin": false]
            list.append(entry)
            setResources(list, kind: kind)
            write(object, to: configurationURL)
        }
        return ["id": id, "name": name, "mime": mime, "builtin": false]
    }

    func deleteResource(kind: String, id: String) -> Bool {
        guard ["roles", "bubbles", "audio"].contains(kind) else { return false }
        var removed: [String: Any]?
        queue.sync {
            var list = resources(kind: kind)
            guard let index = list.firstIndex(where: { ($0["id"] as? String) == id }), list[index]["builtin"] as? Bool != true else { return }
            removed = list.remove(at: index)
            setResources(list, kind: kind)
            write(object, to: configurationURL)
        }
        if let relative = removed?["relativePath"] as? String { try? fileManager.removeItem(at: resourceDirectory.appendingPathComponent(relative)) }
        return removed != nil
    }

    func allResources() -> [String: Any] {
        queue.sync { ["roles": resources(kind: "roles"), "bubbles": resources(kind: "bubbles"), "audio": resources(kind: "audio")] }
    }

    func saveCredential(reference: String, value: String) -> Bool {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReference.isEmpty, !value.isEmpty else { return false }
        let service = "com.404404.AIBalanceWhale.credentials"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: trimmedReference]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func credential(reference: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.404404.AIBalanceWhale.credentials", kSecAttrAccount as String: reference, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func loadAndMigrate() -> [String: Any] {
        guard let data = try? Data(contentsOf: configurationURL), let loaded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let defaults = Self.defaultObject()
            write(defaults, to: configurationURL)
            return defaults
        }
        var merged = Self.defaultObject()
        Self.merge(&merged, loaded)
        if (loaded["schemaVersion"] as? Int ?? 1) < 2 { write(merged, to: configurationURL) }
        return merged
    }

    private func write(_ value: [String: Any], to url: URL) {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func resources(kind: String) -> [[String: Any]] {
        ((object["resources"] as? [String: Any])?[kind] as? [[String: Any]]) ?? []
    }

    private func setResources(_ list: [[String: Any]], kind: String) {
        var all = object["resources"] as? [String: Any] ?? [:]
        all[kind] = list
        object["resources"] = all
    }

    private func sanitizedExtension(name: String, kind: String) -> String {
        let raw = URL(fileURLWithPath: name).pathExtension.lowercased()
        let allowed: Set<String> = kind == "audio" ? ["mp3", "wav", "m4a", "aiff"] : ["png", "jpg", "jpeg", "gif", "webp"]
        return allowed.contains(raw) ? raw : (kind == "audio" ? "wav" : "png")
    }

    private func mimeType(for ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff": return "audio/aiff"
        default: return nil
        }
    }

    private static func merge(_ target: inout [String: Any], _ source: [String: Any]) {
        for (key, value) in source {
            if var left = target[key] as? [String: Any], let right = value as? [String: Any] {
                merge(&left, right); target[key] = left
            } else { target[key] = value }
        }
    }

    private static func defaultObject() -> [String: Any] {
        [
            "schemaVersion": 2,
            "layout": ["scale": 1.0, "alwaysOnTop": false, "allSpaces": false, "mousePassthrough": false, "launchAtLogin": false],
            "appearance": ["snapEnabled": true, "showMenuButton": true, "bubbleEnabled": true, "flip": false, "roleId": "builtin-dsniang"],
            "sound": ["enabled": true, "volume": 0.45, "set": "duck", "press": "Ya1.mp3", "release": "Ya2.mp3", "taskEnd": "end_a"],
            "bubble": ["closeAfterSeconds": 0, "advanceOnClick": true, "steps": [["kind": "status", "text": "Codex 订阅额度"]]],
            "providers": ProviderTemplates.all.filter { (($0["id"] as? String) == "deepseek") || (($0["id"] as? String) == "codex") },
            "reminders": ["enabled": false, "threshold": 20, "budget": NSNull()],
            "records": ["source": "未连接事件来源", "items": []],
            "resources": ["roles": [["id": "builtin-dsniang", "name": "DS娘（默认）", "relativePath": "DSniang1.png", "mime": "image/png", "builtin": true]], "bubbles": [["id": "builtin-money", "name": "金币", "relativePath": "bubble-money1.gif", "mime": "image/gif", "builtin": true], ["id": "builtin-petpet", "name": "Petpet", "relativePath": "bubble-petpet.gif", "mime": "image/gif", "builtin": true]], "audio": [["id": "builtin-press", "name": "按下", "relativePath": "Ya1.mp3", "mime": "audio/mpeg", "builtin": true], ["id": "builtin-release", "name": "松开", "relativePath": "Ya2.mp3", "mime": "audio/mpeg", "builtin": true]],
        ]]
    }
}
