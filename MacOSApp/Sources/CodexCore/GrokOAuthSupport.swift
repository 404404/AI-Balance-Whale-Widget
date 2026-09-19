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

public enum GrokOAuthSupport {
    public static let issuer = "https://auth.x.ai"
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    public static let authorizePath = "/oauth2/authorize"
    public static let tokenPath = "/oauth2/token"
    public static let registeredCallbackPorts: [UInt16] = [56121]
    public static let callbackHost = "127.0.0.1"
    public static let callbackPath = "/callback"

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
        ]
        return components?.url
    }

    public static func validateCallback(_ url: URL, request: GrokOAuthRequest) -> Result<GrokOAuthCallback, CodexOAuthError> {
        guard url.scheme?.lowercased() == "http",
              url.host == callbackHost,
              url.path == callbackPath else { return .failure(CodexOAuthError("授权回调地址不匹配")) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(CodexOAuthError("授权回调无法解析"))
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { return .failure(CodexOAuthError("授权回调包含重复参数")) }
            values[item.name] = item.value ?? ""
        }
        if let error = values["error"], !error.isEmpty {
            return .failure(CodexOAuthError(values["error_description"].map { "授权被拒绝：\($0)" } ?? "授权被拒绝：\(error)"))
        }
        guard values["state"] == request.state else { return .failure(CodexOAuthError("授权 state 校验失败")) }
        guard let code = values["code"], !code.isEmpty else { return .failure(CodexOAuthError("授权回调缺少 code")) }
        return .success(GrokOAuthCallback(code: code, state: request.state))
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
