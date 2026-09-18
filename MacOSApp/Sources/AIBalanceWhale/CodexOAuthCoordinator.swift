import Cocoa
import Foundation
import Network
import CodexCore

/// App-owned browser OAuth. It only accepts the one pending loopback callback,
/// consumes state once, and never exposes tokens to WebKit.
final class CodexOAuthCoordinator {
    var onResult: ((ProviderError?) -> Void)?
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.codex-oauth")
    private var listener: NWListener?
    private var request: CodexOAuthRequest?
    private var consumedState: String?
    private var timeoutWork: DispatchWorkItem?
    private var callbackPortIndex = 0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked(notify: false)
            self.callbackPortIndex = 0
            self.startListenerLocked()
        }
    }

    private func startListenerLocked() {
        guard callbackPortIndex < CodexOAuthSupport.registeredCallbackPorts.count else { finish(.launch("无法监听 Codex 授权回调端口 1455/1457；请关闭占用这些端口的旧授权窗口后重试")); return }
        let callbackPort = CodexOAuthSupport.registeredCallbackPorts[callbackPortIndex]
        let parameters = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: callbackPort) else { finish(.launch("Codex 授权回调端口无效")); return }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
        guard let listener = try? NWListener(using: parameters) else { retryListenerLocked(); return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard self.listener === listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { self.finish(.launch("授权回调端口不可用")); return }
                let request = CodexOAuthSupport.makeRequest(port: port)
                self.request = request
                guard let url = CodexOAuthSupport.authorizationURL(request: request) else { self.finish(.launch("无法生成授权地址")); return }
                self.timeoutWork?.cancel()
                let timeout = DispatchWorkItem { [weak self] in self?.finish(.timeout(stage: "浏览器授权", seconds: 600)) }
                self.timeoutWork = timeout
                self.queue.asyncAfter(deadline: .now() + 600, execute: timeout)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            case .failed:
                self.retryListenerLocked()
            case .cancelled: break
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state { self.finish(.offline("授权回调连接失败：" + error.localizedDescription)) }
            }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    private func retryListenerLocked() {
        timeoutWork?.cancel()
        timeoutWork = nil
        listener?.cancel()
        listener = nil
        request = nil
        callbackPortIndex += 1
        startListenerLocked()
    }

    func cancel() { queue.async { [weak self] in self?.cancelLocked(notify: true) } }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var combined = data
            if let chunk { combined.append(chunk) }
            if let range = combined.range(of: Data("\r\n\r\n".utf8)) {
                let header = combined[..<range.lowerBound]
                let line = String(decoding: header, as: UTF8.self).split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
                let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.handleCallback(target: target, connection: connection)
            } else if !isComplete && error == nil {
                self.receive(connection, data: combined)
            } else if error != nil {
                self.finish(.offline("浏览器未完成授权回调"))
            }
        }
    }

    private func handleCallback(target: String, connection: NWConnection) {
        guard let pending = request else { respond(connection, ok: false); return }
        let callbackURL = URL(string: "http://localhost\(target)")
        let result = callbackURL.map { CodexOAuthSupport.validateCallback($0, request: pending) } ?? .failure(CodexOAuthError("授权回调无法解析"))
        switch result {
        case .failure(let message):
            respond(connection, ok: false)
            if message.message.contains("state") || message.message.contains("code") || message.message.contains("回调") { finish(.protocolError(message.message)) }
        case .success(let callback):
            guard consumedState != pending.state else { respond(connection, ok: false); finish(.protocolError("授权回调重复使用")); return }
            consumedState = pending.state
            respond(connection, ok: true)
            exchange(callback: callback, request: pending)
        }
    }

    private func respond(_ connection: NWConnection, ok: Bool) {
        let title = ok ? "授权完成，可以返回 AI Balance Whale。" : "授权回调无效，请返回应用重试。"
        let body = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n<html><meta charset=\"utf-8\"><body>\(title)</body></html>"
        connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func exchange(callback: CodexOAuthCallback, request: CodexOAuthRequest) {
        guard let url = URL(string: CodexOAuthSupport.issuer + "/oauth/token") else { finish(.protocolError("token endpoint unavailable")); return }
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["grant_type": "authorization_code", "code": callback.code, "redirect_uri": request.redirectURI, "client_id": CodexOAuthSupport.clientID, "code_verifier": request.verifier]
        urlRequest.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                if let error { self.finish(.offline(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let access = object["access_token"] as? String, let idToken = object["id_token"] as? String else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.finish(code == 401 ? .notLoggedIn : .serverError("授权换取凭据失败（HTTP \(code)）")); return
                }
                let account = CodexOAuthSupport.accountID(from: idToken)
                let email = CodexOAuthSupport.displayEmail(from: idToken)
                CodexCredentialStore.shared.save(accessToken: access, refreshToken: object["refresh_token"] as? String, idToken: idToken, expiresIn: (object["expires_in"] as? NSNumber)?.intValue, accountID: account, email: email) { [weak self] saved in
                    guard let self else { return }
                    self.queue.async { self.finish(saved ? nil : .serverError("无法保存 App 授权凭据")) }
                }
            }
        }.resume()
    }

    private func cancelLocked(notify: Bool) {
        timeoutWork?.cancel(); timeoutWork = nil
        listener?.cancel(); listener = nil; request = nil; consumedState = nil
        if notify { finish(.timeout(stage: "浏览器授权已取消", seconds: 0)) }
    }

    private func finish(_ error: ProviderError?) {
        timeoutWork?.cancel(); timeoutWork = nil
        listener?.cancel(); listener = nil; request = nil; consumedState = nil
        DispatchQueue.main.async { [weak self] in self?.onResult?(error) }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
