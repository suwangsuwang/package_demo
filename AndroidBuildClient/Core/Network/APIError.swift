import Foundation

/// 网络层统一错误。
///
/// 约定：**这些错误的描述里不允许出现 Token**，也不允许出现响应体 ——
/// 出错响应可能回显请求上下文，整段丢弃最省心。
enum APIError: Error, Sendable, Equatable {
    /// Keychain 中没有 Token，或读出来的 Token 是空串。
    case missingToken
    /// URL 拼装失败（域名或路径不合法）。
    case invalidURL(String)
    /// `URLSession` 返回了非 HTTP 响应。
    case invalidResponse
    /// 401 / 403：Token 无效或没有权限。
    case unauthorized
    /// 404：接口地址或资源不存在。
    case notFound
    /// 429：请求过于频繁。
    case rateLimited
    /// 5xx：服务端错误。仅保存状态码，不保存响应体。
    case serverError(Int)
    /// 其它非 2xx 状态码。同样只保存状态码。
    case httpStatus(Int)
    /// 响应体不是合法 UTF-8 文本。
    case invalidTextEncoding
    /// JSON 解码失败。附带的是**可读的原因**，由 `reason(for:decoding:)` 生成，
    /// 里面只有字段路径与 Swift 类型名，不含响应体、不含请求头。
    case decodingFailed(String)
    /// 传输层失败（超时、断网等）。
    case network(String)
    /// 客户端所需的配置项尚未填写。
    case configurationMissing(String)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingToken:
            "尚未配置 Yunxiao Token，请先填写 Token。"
        case .invalidURL(let detail):
            "接口地址不合法：\(detail)。"
        case .invalidResponse:
            "服务端返回了无法识别的响应。"
        case .unauthorized:
            "Yunxiao Token 无效或没有权限，请重新填写 Token。"
        case .notFound:
            "接口地址不存在（HTTP 404）。请检查 Yunxiao 域名与流水线 ID 配置。"
        case .rateLimited:
            "请求过于频繁（HTTP 429），请稍后再试。"
        case .serverError(let code):
            "Yunxiao 服务端错误（HTTP \(code)），请稍后再试。"
        case .httpStatus(let code):
            "请求失败，HTTP 状态码 \(code)。"
        case .invalidTextEncoding:
            "响应内容不是合法的 UTF-8 文本。"
        case .decodingFailed(let detail):
            """
            响应解析失败：\(detail)
            这通常表示接口返回的结构与客户端模型不一致，而不是 Token 或配置的问题。
            """
        case .network(let detail):
            "网络请求失败：\(detail)"
        case .configurationMissing(let item):
            "缺少配置：\(item)。请检查 buildconfig.local.json。"
        }
    }

    /// 是否属于「Token 有问题」，UI 可以据此把用户送回 Token 配置页。
    var isAuthenticationFailure: Bool {
        switch self {
        case .missingToken, .unauthorized: true
        default: false
        }
    }
}

extension APIError {

    /// 把 HTTP 状态码映射成错误。
    ///
    /// 这里刻意**不读取响应体**：出错时服务端可能回显部分请求上下文，
    /// 与其担心它是否含 Token，不如整段丢弃。
    static func from(statusCode: Int) -> APIError {
        switch statusCode {
        case 401, 403: .unauthorized
        case 404: .notFound
        case 429: .rateLimited
        case 500...599: .serverError(statusCode)
        default: .httpStatus(statusCode)
        }
    }

    /// 把 `DecodingError` 压成一句能指出**是哪一层不匹配**的话。
    ///
    /// 直接用 `String(describing:)` 会得到一段几十行的 Swift 内部结构树，
    /// 对定位问题毫无帮助；而 `DecodingError` 本身携带的
    /// `codingPath`（哪个字段）与 `debugDescription`（期望什么、实际是什么）
    /// 恰好就是需要的信息，且都来自 Swift 类型系统，
    /// **不包含响应体内容、不包含请求头**。
    static func reason(for error: any Error, decoding type: Any.Type) -> String {
        let target = "\(type)"
        guard let decodingError = error as? DecodingError else {
            return "\(target)：\(String(describing: error))"
        }

        /// `a.b[2].c` 这样的路径，比 `debugDescription` 里的 "at index 2 of ..." 好读。
        func path(_ codingPath: [any CodingKey]) -> String {
            guard !codingPath.isEmpty else { return "响应根节点" }
            return codingPath.reduce(into: "") { result, key in
                if let index = key.intValue {
                    result += "[\(index)]"
                } else {
                    result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            return "\(target) 缺少字段 `\(key.stringValue)`（在 \(path(context.codingPath))）"
        case .typeMismatch(let expected, let context):
            return "\(target) 的 \(path(context.codingPath)) 类型不匹配，期望 \(expected)"
        case .valueNotFound(let expected, let context):
            return "\(target) 的 \(path(context.codingPath)) 值为 null，期望 \(expected)"
        case .dataCorrupted(let context):
            return "\(target) 的 \(path(context.codingPath)) 不是合法 JSON：\(context.debugDescription)"
        @unknown default:
            return "\(target)：未知解析错误"
        }
    }
}
