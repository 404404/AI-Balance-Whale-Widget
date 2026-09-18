import CryptoKit
import Foundation
import Security

/// The small protocol surface shared by the native Codex Auth coordinator and
/// its deterministic acceptance tests. Secrets never leave the native target.
public struct CodexOAuthRequest: Equatable, Sendable {
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

public struct CodexOAuthError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct CodexOAuthCallback: Equatable, Sendable {
    public let code: String
    public let state: String
}

public enum CodexOAuthSupport {
    public static let issuer = "https://auth.openai.com"
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    public static func makeRequest(port: UInt16) -> CodexOAuthRequest {
        makeRequest(port: port, random: { randomBytes(count: 32) })
    }

    public static func makeRequest(port: UInt16, random: () -> Data) -> CodexOAuthRequest {
        let verifier = base64URL(random())
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(digest))
        let state = base64URL(random())
        return CodexOAuthRequest(state: state, verifier: verifier, challenge: challenge, redirectURI: "http://localhost:\(port)/auth/callback")
    }

    public static func authorizationURL(request: CodexOAuthRequest, issuer: String = issuer, clientID: String = clientID) -> URL? {
        var components = URLComponents(string: issuer + "/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: request.redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: request.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: request.state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components?.url
    }

    public static func validateCallback(_ url: URL, request: CodexOAuthRequest) -> Result<CodexOAuthCallback, CodexOAuthError> {
        guard url.scheme?.lowercased() == "http", url.host?.lowercased() == "localhost", url.path == "/auth/callback" else { return .failure(CodexOAuthError("授权回调地址不匹配")) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(CodexOAuthError("授权回调无法解析")) }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { return .failure(CodexOAuthError("授权回调包含重复参数")) }
            values[item.name] = item.value ?? ""
        }
        if let error = values["error"], !error.isEmpty { return .failure(CodexOAuthError(values["error_description"].map { "授权被拒绝：\($0)" } ?? "授权被拒绝：\(error)")) }
        guard values["state"] == request.state else { return .failure(CodexOAuthError("授权 state 校验失败")) }
        guard let code = values["code"], !code.isEmpty else { return .failure(CodexOAuthError("授权回调缺少 code")) }
        return .success(CodexOAuthCallback(code: code, state: request.state))
    }

    public static func parseJWTClaims(_ token: String) -> [String: Any]? {
        let pieces = token.split(separator: ".")
        guard pieces.count >= 2 else { return nil }
        var body = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func accountID(from idToken: String) -> String? {
        let claims = parseJWTClaims(idToken)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let value = (claims?["chatgpt_account_id"] as? String) ?? (auth?["chatgpt_account_id"] as? String)
        return value?.isEmpty == false ? value : nil
    }

    public static func displayEmail(from idToken: String) -> String? {
        let value = parseJWTClaims(idToken)?["email"] as? String
        return value?.isEmpty == false ? value : nil
    }

    private static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
