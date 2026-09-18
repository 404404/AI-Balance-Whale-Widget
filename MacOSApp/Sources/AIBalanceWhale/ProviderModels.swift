import Foundation
import CodexCore

enum ProviderStatus: String, Codable { case idle, loading, ready, stale, cliMissing, notLoggedIn, apiKeyUnsupported, unsupported, offline, error }

struct ProviderState {
    var status: ProviderStatus = .idle
    var message: String = "等待查询 Codex 额度"
    var email: String?
    var planType: String?
    var accountKey: String?
    var buckets: [RateLimitBucket] = []
    var lastUpdated: Date?
    var authSource: String?
    var requestID: String?
}

enum ProviderError: LocalizedError {
    case launch(String)
    case timeout(stage: String, seconds: Int)
    case processExited(stage: String)
    case protocolError(String)
    case serverError(String)
    case notLoggedIn
    case apiKeyUnsupported
    case unsupported(String)
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .launch(let message): return "无法启动授权：\(message)"
        case .timeout(let stage, let seconds): return "Codex 在\(stage)阶段等待\(seconds)秒超时，请重试"
        case .processExited(let stage): return "Codex 在\(stage)阶段退出"
        case .protocolError(let message): return "Codex 协议错误：\(message)"
        case .serverError(let message): return message
        case .notLoggedIn: return "尚未连接 ChatGPT/Codex 账户"
        case .apiKeyUnsupported: return "API Key 不能读取 ChatGPT 订阅额度，请使用 ChatGPT 登录"
        case .unsupported(let message): return message
        case .offline(let message): return "额度查询失败：\(message)"
