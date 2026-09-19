import CryptoKit
import Foundation
import Security

public struct CursorOAuthRequest: Equatable, Sendable {
    public let uuid: String
    public let verifier: String
    public let challenge: String
    public let loginURL: URL

    public init(uuid: String, verifier: String, challenge: String, loginURL: URL) {
        self.uuid = uuid
        self.verifier = verifier
        self.challenge = challenge
        self.loginURL = loginURL
    }
}

public struct CursorOAuthTokens: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let userID: String?

    public init(accessToken: String, refreshToken: String, userID: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
    }
}

public enum CursorOAuthSupport {
    public static let loginURL = "https://cursor.com/loginDeepControl"
    public static let pollURL = "https://api2.cursor.sh/auth/poll"
    public static let refreshURL = "https://api2.cursor.sh/auth/exchange_user_api_key"

    public static func makeRequest() -> CursorOAuthRequest {
        makeRequest(uuid: UUID().uuidString.lowercased(), random: { randomBytes(count: 32) })
    }

    public static func makeRequest(uuid: String, random: () -> Data) -> CursorOAuthRequest {
        let verifier = base64URL(random())
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: loginURL)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        return CursorOAuthRequest(uuid: uuid, verifier: verifier, challenge: challenge, loginURL: components.url!)
    }

    public static func pollURL(request: CursorOAuthRequest) -> URL {
        var components = URLComponents(string: pollURL)!
        components.queryItems = [
            URLQueryItem(name: "uuid", value: request.uuid),
            URLQueryItem(name: "verifier", value: request.verifier),
        ]
        return components.url!
    }

    public static func parsePoll(_ object: Any) -> Result<CursorOAuthTokens, CodexOAuthError> {
        guard let dictionary = object as? [String: Any] else {
            return .failure(CodexOAuthError("Cursor 授权响应无法解析"))
        }
        let access = (dictionary["accessToken"] as? String) ?? (dictionary["access_token"] as? String)
        let refresh = (dictionary["refreshToken"] as? String) ?? (dictionary["refresh_token"] as? String) ?? ""
        let user = (dictionary["userId"] as? String) ?? (dictionary["authId"] as? String) ?? (dictionary["user_id"] as? String)
        guard let access, !access.isEmpty else {
            return .failure(CodexOAuthError("Cursor 授权尚未完成"))
        }
        return .success(CursorOAuthTokens(accessToken: access, refreshToken: refresh, userID: user))
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
