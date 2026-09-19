import CryptoKit
import Foundation
import Security

public struct GrokOAuthRequest: Equatable, Sendable {
    public let state: String
    public let verifier: String
    public let challenge: String
    public let redirectURI: String

    public init(state: String, verifier: String, challenge: String, redirectURI: String) {
        self.state = state
        self.verifier = verifier
        self.challenge = challenge
        self.redirectURI = redirectURI
    }
}

public struct GrokOAuthCallback: Equatable, Sendable {
    public let code: String
    public let state: String
}

public struct GrokLoopbackRequest: Equatable, Sendable {
    public let method: String
    public let target: String
    public let origin: String?
    public let requestsPrivateNetwork: Bool
    public let expectedBodyLength: Int
    public let body: Data

    public var isComplete: Bool { body.count >= expectedBodyLength }
}

public enum GrokOAuthSupport {
    public static let issuer = "https://auth.x.ai"
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    public static let authorizePath = "/oauth2/authorize"
    public static let tokenPath = "/oauth2/token"
    public static let registeredCallbackPorts: [UInt16] = [56121]
    public static let callbackHost = "127.0.0.1"
    public static let callbackPath = "/callback"
    public static let authorizeReferrer = "grok-build"
    public static let trustedOrigins: Set<String> = [
        "https://auth.x.ai",
        "https://accounts.x.ai",
        "https://accounts.x.com",
    ]

    public static func makeRequest(port: UInt16 = registeredCallbackPorts[0]) -> GrokOAuthRequest {
        makeRequest(port: port, random: { randomBytes(count: 32) })
    }

    public static func makeRequest(port: UInt16, random: () -> Data) -> GrokOAuthRequest {
        let verifier = base64URL(random())
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = base64URL(random())
        return GrokOAuthRequest(
            state: state,
            verifier: verifier,
            challenge: challenge,
            redirectURI: "http://\(callbackHost):\(port)\(callbackPath)"
        )
    }

    public static func authorizationURL(request: GrokOAuthRequest) -> URL? {
        var components = URLComponents(string: issuer + authorizePath)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: request.redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: request.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: request.state),
            URLQueryItem(name: "referrer", value: authorizeReferrer),
        ]
        return components?.url
    }

    public static func isTrustedCallbackHost(_ host: String?) -> Bool {
        host == callbackHost || host == "localhost"
    }

    public static func isTrustedOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return false }
        return trustedOrigins.contains(origin)
    }

    public static func validateCallback(_ url: URL, request: GrokOAuthRequest) -> Result<GrokOAuthCallback, CodexOAuthError> {
        guard url.scheme?.lowercased() == "http",
              isTrustedCallbackHost(url.host),
              url.path == callbackPath else { return .failure(CodexOAuthError("授权回调地址不匹配")) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(CodexOAuthError("授权回调无法解析"))
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { return .failure(CodexOAuthError("授权回调包含重复参数")) }
            values[item.name] = item.value ?? ""
        }
        return callback(from: values, request: request)
    }

    public static func parseLoopback(_ data: Data) -> GrokLoopbackRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8)) else { return nil }
        let headerText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        let separator = headerText.contains("\r\n") ? "\r\n" : "\n"
        let lines = headerText.components(separatedBy: separator).filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ").map(String.init)
        let method = (parts.first ?? "GET").uppercased()
        let target = parts.dropFirst().first ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let privateNetwork = headers.contains { $0.key.contains("private-network") && $0.value.lowercased() == "true" }
        return GrokLoopbackRequest(
            method: method,
            target: target,
            origin: headers["origin"],
            requestsPrivateNetwork: privateNetwork,
            expectedBodyLength: Int(headers["content-length"] ?? "0") ?? 0,
            body: Data(data[range.upperBound...])
        )
    }

    public static func extractCallback(target: String, body: Data, request: GrokOAuthRequest) -> Result<GrokOAuthCallback, CodexOAuthError> {
        let path = target.hasPrefix("/") ? target : "/" + target
        if let url = URL(string: "http://\(callbackHost)\(path)"),
           case .success(let callback) = validateCallback(url, request: request) {
            return .success(callback)
        }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            var values: [String: String] = [:]
            for (key, value) in object { values[key] = String(describing: value) }
            if case .success(let callback) = callback(from: values, request: request) { return .success(callback) }
        }
        if let form = String(data: body, encoding: .utf8), !form.isEmpty {
            var values: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { continue }
                values[pieces[0]] = pieces[1].removingPercentEncoding ?? pieces[1]
            }
            return callback(from: values, request: request)
        }
        return .failure(CodexOAuthError("授权回调缺少 code"))
    }

    public static func httpResponse(status: Int, origin: String?, allowPrivateNetwork: Bool, html: String) -> Data {
        var lines = [
            "HTTP/1.1 \(status) \(status == 204 ? "No Content" : "OK")",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        if let origin, isTrustedOrigin(origin) {
            lines.append("Access-Control-Allow-Origin: \(origin)")
            lines.append("Access-Control-Allow-Credentials: true")
            lines.append("Access-Control-Allow-Methods: GET, POST, OPTIONS")
            lines.append("Access-Control-Allow-Headers: content-type")
            lines.append("Vary: Origin")
        }
        if allowPrivateNetwork {
            lines.append("Access-Control-Allow-Private-Network: true")
        }
        if status == 204 {
            lines.append("Content-Length: 0")
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
        let payload = Data(html.utf8)
        lines.append("Content-Type: text/html; charset=utf-8")
        lines.append("Content-Length: \(payload.count)")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(payload)
        return data
    }

    public static func displayEmail(from idToken: String) -> String? {
        let value = CodexOAuthSupport.parseJWTClaims(idToken)?["email"] as? String
        return value?.isEmpty == false ? value : nil
    }

    public static func accountID(from idToken: String, accessToken: String) -> String {
        let claims = CodexOAuthSupport.parseJWTClaims(idToken) ?? CodexOAuthSupport.parseJWTClaims(accessToken)
        let value = (claims?["sub"] as? String) ?? (claims?["email"] as? String) ?? "grok"
        return value
    }

    private static func callback(from values: [String: String], request: GrokOAuthRequest) -> Result<GrokOAuthCallback, CodexOAuthError> {
        if let error = values["error"], !error.isEmpty {
            return .failure(CodexOAuthError(values["error_description"].map { "授权被拒绝：\($0)" } ?? "授权被拒绝：\(error)"))
        }
        guard values["state"] == request.state else { return .failure(CodexOAuthError("授权 state 校验失败")) }
        guard let code = values["code"], !code.isEmpty else { return .failure(CodexOAuthError("授权回调缺少 code")) }
        return .success(GrokOAuthCallback(code: code, state: request.state))
    }

    private static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
