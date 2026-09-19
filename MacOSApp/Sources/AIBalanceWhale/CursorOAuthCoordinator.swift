import Cocoa
import Foundation
import CodexCore

/// Cursor browser login: open loginDeepControl, then poll until the user confirms.
final class CursorOAuthCoordinator {
    var onResult: ((ProviderError?) -> Void)?
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.cursor-oauth")
    private var session: URLSession?
    private var pollTask: URLSessionDataTask?
    private var timeoutWork: DispatchWorkItem?
    private var cancelled = false
    private var finished = false

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked(notify: false)
            self.cancelled = false
            self.finished = false
            let request = CursorOAuthSupport.makeRequest()
            self.session = URLSession(configuration: .ephemeral)
            self.timeoutWork?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.serverError("Cursor 浏览器授权超时，请重试")) }
            self.timeoutWork = timeout
            self.queue.asyncAfter(deadline: .now() + 300, execute: timeout)
            DispatchQueue.main.async { NSWorkspace.shared.open(request.loginURL) }
            self.poll(request: request, delay: 1)
        }
    }

    func cancel() { queue.async { [weak self] in self?.cancelLocked(notify: true) } }

    private func poll(request: CursorOAuthRequest, delay: TimeInterval) {
        guard !cancelled else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.cancelled, let session = self.session else { return }
            var urlRequest = URLRequest(url: CursorOAuthSupport.pollURL(request: request), timeoutInterval: 20)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            self.pollTask = session.dataTask(with: urlRequest) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    guard !self.cancelled else { return }
                    if error != nil {
                        self.poll(request: request, delay: min(delay * 1.2, 5))
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 404 {
                        self.poll(request: request, delay: min(max(delay, 1) * 1.2, 5))
                        return
                    }
                    if status == 429 {
                        self.poll(request: request, delay: min(delay * 1.5, 8))
                        return
                    }
                    if status == 401 || status == 403 || status == 410 {
                        self.finish(.serverError("Cursor 授权被拒绝或已过期，请重新连接"))
                        return
                    }
                    guard (200...299).contains(status), let data, let object = try? JSONSerialization.jsonObject(with: data) else {
                        self.poll(request: request, delay: min(delay * 1.2, 5))
                        return
                    }
                    switch CursorOAuthSupport.parsePoll(object) {
                    case .failure:
                        self.poll(request: request, delay: min(delay * 1.2, 5))
                    case .success(let tokens):
                        SubscriptionCredentialStore.cursor.save(
                            accessToken: tokens.accessToken,
                            refreshToken: tokens.refreshToken.isEmpty ? nil : tokens.refreshToken,
                            accountID: tokens.userID ?? "cursor",
                            email: tokens.userID,
                            expiresIn: nil
                        ) { [weak self] saved in
                            self?.queue.async { self?.finish(saved ? nil : .serverError("无法保存 App 授权凭据")) }
                        }
                    }
                }
            }
            self.pollTask?.resume()
        }
    }

    private func cancelLocked(notify: Bool) {
        cancelled = true
        timeoutWork?.cancel(); timeoutWork = nil
        pollTask?.cancel(); pollTask = nil
        session?.invalidateAndCancel(); session = nil
        if notify { finish(.serverError("已取消 Cursor 浏览器授权")) }
    }

    private func finish(_ error: ProviderError?) {
        guard !finished else { return }
        finished = true
        cancelled = true
        timeoutWork?.cancel(); timeoutWork = nil
        pollTask?.cancel(); pollTask = nil
        session?.finishTasksAndInvalidate(); session = nil
        DispatchQueue.main.async { [weak self] in self?.onResult?(error) }
    }
}
