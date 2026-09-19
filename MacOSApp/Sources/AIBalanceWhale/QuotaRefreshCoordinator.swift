import Foundation
import CodexCore

/// Coordinates provider refreshes. Codex is an independent App-owned HTTP
/// source; its auth lifecycle never starts, stops or reads a CLI process.
final class QuotaRefreshCoordinator {
    var onAccountsUpdated: (([[String: Any]]) -> Void)?
    var onCodexConnection: ((ProviderState) -> Void)?

    private let store = WhaleConfigurationStore.shared
    private let codex = CodexHTTPUsageClient()
    private let external = ExternalProviderClient()
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.quota")
    private var generation = 0
    private var sleeping = false
    private var pending = 0
    private var latestCodex = ProviderState()
    private var codexDisconnected = false

    init() {
        codex.onStateChange = { [weak self] state in self?.handleCodex(state) }
    }

    func refresh() { queue.async { [weak self] in self?.refreshLocked() } }
    func refreshAccount(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if id == "codex" { self.codexDisconnected = false }
            self.refreshLocked(only: id)
        }
    }
    func configurationChanged() { queue.async { [weak self] in self?.codexDisconnected = false; self?.refreshLocked() } }

    func noteBrowserAuthError(provider: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(id: provider, patch: [
                "status": "error",
                "message": message,
            ], generation: self.generation, keepLastOnEmptyWindows: true)
        }
    }

    func disconnectBrowserAuth(provider: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if provider == "codex" {
                self.disconnectCodex()
                return
            }
            SubscriptionCredentialStore.store(for: provider)?.disconnect()
            let label = AccountCatalog.providerMeta[provider]?["label"] ?? provider
            self.apply(id: provider, patch: [
                "status": "notLoggedIn",
                "message": "已断开本 App 授权；不会注销其他 \(label) 登录",
                "windows": [] as [[String: Any]],
                "updatedAt": NSNull(),
            ], generation: self.generation, keepLastOnEmptyWindows: false)
        }
    }
    func disconnectCodex() {
        queue.async { [weak self] in
            guard let self else { return }
            self.codexDisconnected = true
            self.codex.stopImmediately()
            CodexCredentialStore.shared.disconnect()
            self.latestCodex = ProviderState(status: .notLoggedIn, message: "已断开本 App 授权；不会注销其他 Codex 登录", authSource: "app-keychain")
            self.emitCodex()
            self.apply(id: "codex", patch: ["status": "notLoggedIn", "message": self.latestCodex.message, "windows": [] as [[String: Any]], "updatedAt": NSNull()], generation: self.generation, keepLastOnEmptyWindows: false)
        }
    }

    func setSleeping(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sleeping = value
            self.codex.setSleeping(value)
            if !value { self.refreshLocked() }
        }
    }
    func stopImmediately() { codex.stopImmediately() }

    private func refreshLocked(only: String? = nil) {
        guard !sleeping else { return }
        generation += 1
        let current = generation
        let accounts = store.accounts()
        let targets = accounts.filter { account in
            (account["enabled"] as? Bool) != false && (only == nil || (account["id"] as? String) == only)
        }
        pending = 0
        publish()
        for account in targets {
            let id = account["id"] as? String ?? ""
            let provider = account["provider"] as? String ?? id
            let authMode = account["authMode"] as? String ?? "demo"
            let keyRef = account["keyRef"] as? String ?? "account.\(id)"
            let token = store.credential(reference: keyRef) ?? ""
            let hasToken = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if provider == "codex" {
                guard !codexDisconnected else { continue }
                pending += 1
                latestCodex = ProviderState(status: .loading, message: "正在查询 Codex 额度…", authSource: "app-keychain", requestID: String(current))
                emitCodex()
                codex.refresh(requestID: String(current))
                continue
            }
            if let browserStore = SubscriptionCredentialStore.store(for: provider) {
                pending += 1
                browserStore.accessToken { [weak self] result in
                    guard let self else { return }
                    self.queue.async {
                        switch result {
                        case .failure:
                            self.apply(
                                id: id,
                                patch: ["status": "notLoggedIn", "message": "尚未连接 \(AccountCatalog.providerMeta[provider]?["label"] ?? provider) 账户"],
                                generation: current,
                                keepLastOnEmptyWindows: true
                            )
                            self.finishOne(current)
                        case .success(let credential):
                            self.external.fetch(provider: provider, token: credential.accessToken) { [weak self] fetch in
                                self?.queue.async { self?.finishExternal(id: id, result: fetch, generation: current) }
                            }
                        }
                    }
                }
                continue
            }
            if !AccountCatalog.shouldLiveFetch(provider: provider, authMode: authMode, hasToken: hasToken) {
                apply(id: id, patch: ["status": "demo", "message": "演示数据。连接真实账户后点刷新才会读取接口。"], generation: current)
                continue
            }
            pending += 1
            external.fetch(provider: provider, token: token) { [weak self] result in
                self?.queue.async { self?.finishExternal(id: id, result: result, generation: current) }
            }
        }
    }

    private func handleCodex(_ state: ProviderState) {
        queue.async { [weak self] in
            guard let self, let requestID = state.requestID, requestID == String(self.generation), !self.codexDisconnected else { return }
            self.latestCodex = state
            self.emitCodex()
            guard state.status != .loading else { return }
            if state.status == .ready || state.status == .stale {
                self.applyCodex(state, generation: self.generation)
            } else {
                self.applyCodexFailure(state, generation: self.generation)
            }
        }
    }

    private func applyCodex(_ state: ProviderState, generation: Int) {
        var patch: [String: Any] = ["status": state.status == .stale ? "stale" : "ok", "message": state.message]
        if let date = state.lastUpdated { patch["updatedAt"] = date.timeIntervalSince1970 * 1000 }
        let windows = AccountCatalog.windows(from: state.buckets)
        if !windows.isEmpty { patch["windows"] = windows.map(\.dictionary) }
        apply(id: "codex", patch: patch, generation: generation, keepLastOnEmptyWindows: true)
        finishOne(generation)
    }

    private func applyCodexFailure(_ state: ProviderState, generation: Int) {
        let accounts = store.accounts()
        let hasCache = accounts.first(where: { ($0["id"] as? String) == "codex" })?["windows"] as? [[String: Any]] ?? []
        apply(id: "codex", patch: ["status": hasCache.isEmpty ? "error" : "stale", "message": hasCache.isEmpty ? state.message : "额度查询失败，显示的是上次成功快照：\(state.message)"], generation: generation, keepLastOnEmptyWindows: true)
        finishOne(generation)
    }

    private func finishExternal(id: String, result: QuotaFetchSnapshot, generation: Int) {
        var patch: [String: Any] = ["status": result.ok ? "ok" : "error", "message": result.message, "updatedAt": Date().timeIntervalSince1970 * 1000]
        if result.ok {
            if !result.windows.isEmpty { patch["windows"] = result.windows.map(\.dictionary) }
            if let value = result.remaining { patch["remaining"] = value }
            if let value = result.used { patch["used"] = value }
            if let value = result.total { patch["total"] = value }
        }
        apply(id: id, patch: patch, generation: generation, keepLastOnEmptyWindows: true)
        finishOne(generation)
    }

    private func apply(id: String, patch: [String: Any], generation: Int, keepLastOnEmptyWindows: Bool = false) {
        guard generation == self.generation else { return }
        var accounts = store.accounts()
        guard let index = accounts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        var next = accounts[index]
        let previousWindows = next["windows"]
        let previousRemaining = next["remaining"]
        let previousUsed = next["used"]
        let previousTotal = next["total"]
        for (key, value) in patch {
            if value is NSNull { next.removeValue(forKey: key) } else { next[key] = value }
        }
        if keepLastOnEmptyWindows {
            if (next["windows"] as? [[String: Any] ] ?? []).isEmpty, previousWindows != nil { next["windows"] = previousWindows }
            if next["remaining"] == nil, previousRemaining != nil { next["remaining"] = previousRemaining }
            if next["used"] == nil, previousUsed != nil { next["used"] = previousUsed }
            if next["total"] == nil, previousTotal != nil { next["total"] = previousTotal }
        }
        accounts[index] = AccountCatalog.stripSecret(next)
        store.replaceAccounts(accounts)
        publish()
    }

    private func finishOne(_ generation: Int) { guard generation == self.generation else { return }; pending = max(0, pending - 1) }
    private func publish() { let accounts = store.publicAccounts(); DispatchQueue.main.async { [weak self] in self?.onAccountsUpdated?(accounts) } }
    private func emitCodex() { let state = latestCodex; DispatchQueue.main.async { [weak self] in self?.onCodexConnection?(state) } }
}
