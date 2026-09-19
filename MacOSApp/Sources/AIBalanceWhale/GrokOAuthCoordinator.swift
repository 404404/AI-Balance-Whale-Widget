import Cocoa
import Foundation
import Network
import CodexCore

/// App-owned Grok browser OAuth. Tokens never enter WebKit.
/// xAI's authorize page often fetches 127.0.0.1:56121 via CORS instead of a
/// top-level redirect; without preflight + Private Network Access headers the
/// page falls back to "paste this code".
final class GrokOAuthCoordinator {
    var onResult: ((ProviderError?) -> Void)?
    private let queue = DispatchQueue(label: "com.404404.AIBalanceWhale.grok-oauth")
    private var listener: NWListener?
    private var request: GrokOAuthRequest?
    private var consumedState: String?
    private var timeoutWork: DispatchWorkItem?
    private var session: URLSession?
    private var finished = false

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelLocked(notify: false)
            self.finished = false
            self.startListenerLocked()
        }
    }

    func cancel() { queue.async { [weak self] in self?.cancelLocked(notify: true) } }

    private func startListenerLocked() {
        let callbackPort = GrokOAuthSupport.registeredCallbackPorts[0]
        let parameters = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: callbackPort) else { finish(.launch("Grok 授权回调端口无效")); return }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(GrokOAuthSupport.callbackHost), port: port)
        guard let listener = try? NWListener(using: parameters) else {
            finish(.launch("无法监听 Grok 授权回调端口 56121；请关闭占用该端口的旧授权窗口后重试"))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready:
                let request = GrokOAuthSupport.makeRequest(port: callbackPort)
                self.request = request
                guard let url = GrokOAuthSupport.authorizationURL(request: request) else { self.finish(.launch("无法生成授权地址")); return }
                self.timeoutWork?.cancel()
                let timeout = DispatchWorkItem { [weak self] in self?.finish(.serverError("Grok 浏览器授权超时，请重试")) }
                self.timeoutWork = timeout
                self.queue.asyncAfter(deadline: .now() + 600, execute: timeout)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            case .failed:
                self.finish(.launch("无法监听 Grok 授权回调端口 56121；请关闭占用该端口的旧授权窗口后重试"))
            case .cancelled: break
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.finish(.offline("授权回调连接失败：" + error.localizedDescription)) }
            }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var combined = data
            if let chunk { combined.append(chunk) }
            if let parsed = GrokOAuthSupport.parseLoopback(combined), parsed.isComplete {
                self.handleCallback(parsed, connection: connection)
            } else if !isComplete && error == nil {
                self.receive(connection, data: combined)
            } else if error != nil {
                self.finish(.offline("浏览器未完成授权回调"))
            }
        }
    }

    private func handleCallback(_ incoming: GrokLoopbackRequest, connection: NWConnection) {
        let allowPrivate = incoming.requestsPrivateNetwork || GrokOAuthSupport.isTrustedOrigin(incoming.origin)
        if incoming.method == "OPTIONS" {
            let payload = GrokOAuthSupport.httpResponse(status: 204, origin: incoming.origin, allowPrivateNetwork: allowPrivate, html: "")
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        guard let pending = request else {
            respond(connection, ok: false, origin: incoming.origin, allowPrivate: allowPrivate)
            return
        }
        switch GrokOAuthSupport.extractCallback(target: incoming.target, body: incoming.body, request: pending) {
        case .failure(let message):
            respond(connection, ok: false, origin: incoming.origin, allowPrivate: allowPrivate)
            finish(.protocolError(message.message))
        case .success(let callback):
            guard consumedState != pending.state else {
                respond(connection, ok: false, origin: incoming.origin, allowPrivate: allowPrivate)
                finish(.protocolError("授权回调重复使用"))
                return
            }
            consumedState = pending.state
            respond(connection, ok: true, origin: incoming.origin, allowPrivate: allowPrivate)
            exchange(callback: callback, request: pending)
        }
    }

    private func respond(_ connection: NWConnection, ok: Bool, origin: String?, allowPrivate: Bool) {
        let title = ok ? "授权完成，可以返回 AI Balance Whale。" : "授权回调无效，请返回应用重试。"
        let html = "<html><meta charset=\"utf-8\"><body>\(title)</body></html>"
        let payload = GrokOAuthSupport.httpResponse(status: 200, origin: origin, allowPrivateNetwork: allowPrivate, html: html)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func exchange(callback: GrokOAuthCallback, request: GrokOAuthRequest) {
        guard let url = URL(string: GrokOAuthSupport.issuer + GrokOAuthSupport.tokenPath) else { finish(.protocolError("token endpoint unavailable")); return }
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "grant_type": "authorization_code",
            "code": callback.code,
            "redirect_uri": request.redirectURI,
            "client_id": GrokOAuthSupport.clientID,
            "code_verifier": request.verifier,
        ]
        urlRequest.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)
        let session = URLSession(configuration: .ephemeral, delegate: HTTPNoRedirectDelegate(), delegateQueue: nil)
        self.session = session
        session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                if let error { self.finish(.offline(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = object["access_token"] as? String else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.finish(code == 401 ? .notLoggedIn : .serverError("授权换取凭据失败（HTTP \(code)）"))
                    return
                }
                let idToken = object["id_token"] as? String
                let email = idToken.flatMap(GrokOAuthSupport.displayEmail)
                let account = GrokOAuthSupport.accountID(from: idToken ?? "", accessToken: access)
                SubscriptionCredentialStore.grok.save(
                    accessToken: access,
                    refreshToken: object["refresh_token"] as? String,
                    accountID: account,
                    email: email,
                    expiresIn: (object["expires_in"] as? NSNumber)?.intValue
                ) { [weak self] saved in
                    self?.queue.async { self?.finish(saved ? nil : .serverError("无法保存 App 授权凭据")) }
                }
            }
        }.resume()
    }

    private func cancelLocked(notify: Bool) {
        timeoutWork?.cancel(); timeoutWork = nil
        listener?.cancel(); listener = nil; request = nil; consumedState = nil
        session?.invalidateAndCancel(); session = nil
        if notify { finish(.serverError("已取消 Grok 浏览器授权")) }
    }

    private func finish(_ error: ProviderError?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel(); timeoutWork = nil
        listener?.cancel(); listener = nil; request = nil; consumedState = nil
        session?.finishTasksAndInvalidate(); session = nil
        DispatchQueue.main.async { [weak self] in self?.onResult?(error) }
    }
}
