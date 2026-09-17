import Foundation
import CodexCore

/// Refreshes every enabled account in parallel. Codex prefers local app-server,
/// then the WHAM HTTP client, then a pasted session token. Failed fetches keep
/// the last successful windows/balance so the bubble never goes blank.
final class QuotaRefreshCoordinator {
    var onAccountsUpdated: (([[String: Any]]) -> Void)?
    var onCodexConnection: ((ProviderState) -> Void)?

    private let store = WhaleConfigurationStore.shared
    private let appServer = CodexAppServerClient()
    private let http = CodexHTTPUsageClient()
    private let external = ExternalProviderClient()
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.quota")
    private var generation = 0
    private var sleeping = false
    private var pending = 0
    private var restartCodex = false
    private var latestCodex = ProviderState()

    init() {
        appServer.onStateChange = { [weak self] state in
            self?.handleCodex(state, source: .appServer)
        }
        http.onStateChange = { [weak self] state in
            self?.handleCodex(state, source: .http)
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.refreshLocked() }
    }

    func refreshAccount(id: String) {
        queue.async { [weak self] in self?.refreshLocked(only: id) }
    }

    func configurationChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.restartCodex = true
            self.refreshLocked()
        }
    }

    func setSleeping(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sleeping = value
            self.appServer.setSleeping(value)
            self.http.setSleeping(value)
            if !value { self.refreshLocked() }
        }
    }

    func stopImmediately() {
        appServer.stopImmediately()
        http.stopImmediately()
    }

    private enum CodexSource { case appServer, http }

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

            if authMode != "token" || (provider != "codex" && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                if provider == "codex" { restartCodex = false }
                apply(id: id, patch: [
                    "status": "demo",
                    "message": "演示数据。填登录态后点刷新才会打真实接口。",
                ], generation: current)
                continue
            }

            if provider == "codex" {
                pending += 1
                latestCodex.status = .loading
                latestCodex.message = "正在查询 Codex 额度…"
                emitCodex()
                if restartCodex {
                    restartCodex = false
                    appServer.configurationChanged()
                } else {
                    appServer.refresh()
                }
                continue
            }

            pending += 1
            external.fetch(provider: provider, token: token) { [weak self] result in
                self?.queue.async {
                    self?.finishExternal(id: id, current: account, result: result, generation: current)
                }
            }
        }
    }

    private func handleCodex(_ state: ProviderState, source: CodexSource) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestCodex = state
            self.emitCodex()
            let success = state.status == .ready || state.status == .stale
            if success {
                self.applyCodex(state, generation: self.generation)
                return
            }
            if source == .appServer, self.shouldFallback(state) {
                self.http.refresh()
                return
            }
            if source == .http, self.shouldFallback(state) {
                let token = self.store.credential(reference: "account.codex") ?? ""
                if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.external.fetch(provider: "codex", token: token) { [weak self] result in
                        self?.queue.async {
                            guard let self else { return }
                            if result.ok {
                                self.finishExternal(id: "codex", current: self.account("codex"), result: result, generation: self.generation)
                            } else {
                                self.applyCodexFailure(state.message, generation: self.generation)
                            }
                        }
                    }
                    return
                }
            }
            if state.status != .loading && state.status != .idle {
                self.applyCodexFailure(state.message, generation: self.generation)
            }
        }
    }

    private func shouldFallback(_ state: ProviderState) -> Bool {
        switch state.status {
        case .cliMissing, .notLoggedIn, .offline, .error, .unsupported, .apiKeyUnsupported:
            return true
        default:
            return false
        }
    }

    private func applyCodex(_ state: ProviderState, generation: Int) {
        let windows = AccountCatalog.windows(from: state.buckets)
        var patch: [String: Any] = [
            "status": state.status == .stale ? "error" : "ok",
            "message": state.message,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
        ]
        if !windows.isEmpty {
            patch["windows"] = windows.map(\.dictionary)
        }
        if state.status == .stale {
            patch["status"] = "ok"
            patch["message"] = state.message
        }
        apply(id: "codex", patch: patch, generation: generation, keepLastOnEmptyWindows: true)
        finishOne()
    }

    private func applyCodexFailure(_ message: String, generation: Int) {
        apply(id: "codex", patch: [
            "status": "error",
            "message": message,
        ], generation: generation, keepLastOnEmptyWindows: true)
        finishOne()
    }

    private func finishExternal(id: String, current: [String: Any], result: QuotaFetchSnapshot, generation: Int) {
        var patch: [String: Any] = [
            "status": result.ok ? "ok" : "error",
            "message": result.message,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
        ]
        if result.ok {
            if !result.windows.isEmpty { patch["windows"] = result.windows.map(\.dictionary) }
            if let remaining = result.remaining { patch["remaining"] = remaining }
            if let used = result.used { patch["used"] = used }
            if let total = result.total { patch["total"] = total }
        }
        apply(id: id, patch: patch, generation: generation, keepLastOnEmptyWindows: true)
        finishOne()
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
        for (key, value) in patch { next[key] = value }
        if keepLastOnEmptyWindows {
            let newWindows = next["windows"] as? [[String: Any]] ?? []
            if newWindows.isEmpty, previousWindows != nil { next["windows"] = previousWindows }
            if next["remaining"] == nil, previousRemaining != nil { next["remaining"] = previousRemaining }
            if next["used"] == nil, previousUsed != nil { next["used"] = previousUsed }
            if next["total"] == nil, previousTotal != nil { next["total"] = previousTotal }
        }
        accounts[index] = AccountCatalog.stripSecret(next)
        store.replaceAccounts(accounts)
        publish()
    }

    private func finishOne() {
        pending = max(0, pending - 1)
    }

    private func account(_ id: String) -> [String: Any] {
        store.accounts().first { ($0["id"] as? String) == id } ?? [:]
    }

    private func publish() {
        let accounts = store.publicAccounts()
        DispatchQueue.main.async { [weak self] in self?.onAccountsUpdated?(accounts) }
    }

    private func emitCodex() {
        let state = latestCodex
        DispatchQueue.main.async { [weak self] in self?.onCodexConnection?(state) }
    }
}
