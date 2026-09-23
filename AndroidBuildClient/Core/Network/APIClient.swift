import Foundation

/// 统一网络层。
///
/// 面向具体请求而不是泛型构建器：Service 负责拼 `URLRequest`（含路径、查询、请求体），
/// 这里负责发送、注入认证信息、判定状态码、解码。
///
/// **Token 注入只在这里发生**，各 Service 不允许自己设置 `x-yunxiao-token`，
/// 也不允许把 Token 放进 URL Query。
protocol APIClientProtocol: Sendable {

    /// 会被注入 Token 的请求头字段。仅用于展示，值是占位符。
    var tokenHeaderFields: [String] { get }

    /// 发送请求，返回原始响应体与 HTTP 响应头。
    ///
    /// 不对状态码做要求 —— 需要自行判断（例如轮询接口想区分 404）。
    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)

    /// 发送请求，要求 2xx，按 `T` 解码响应体。
    func send<T: Decodable & Sendable>(_ request: URLRequest, decoding type: T.Type) async throws -> T

    /// 发送请求，要求 2xx，把响应体当 UTF-8 文本返回。
    func send(_ request: URLRequest) async throws -> String
}

extension APIClientProtocol {

    func send<T: Decodable & Sendable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let (data, response) = try await send(request)
        try Self.checkStatus(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(APIError.reason(for: error, decoding: T.self))
        }
    }

    /// 与 `send(_:decoding:)` 完全相同，但同时把 **HTTP 响应头**交回调用方。
    ///
    /// 存在的理由只有一个：分页信息只在响应头里
    /// （`x-next-page` / `x-total-pages` / `x-total`），
    /// 只要响应体就判断不出"还有没有下一页"，于是"翻到最后一页"这件事
    /// 只能靠猜。这不是给网络层加业务 —— 它照样不知道 Codeup / 分支是什么，
    /// 只是把本来就拿到手的响应头一并交出去。
    func sendWithResponse<T: Decodable & Sendable>(
        _ request: URLRequest,
        decoding type: T.Type
    ) async throws -> (value: T, response: HTTPURLResponse) {
        let (data, response) = try await send(request)
        try Self.checkStatus(response)
        do {
            return (try JSONDecoder().decode(T.self, from: data), response)
        } catch {
            throw APIError.decodingFailed(APIError.reason(for: error, decoding: T.self))
        }
    }

    func send(_ request: URLRequest) async throws -> String {
        let (data, response) = try await send(request)
        try Self.checkStatus(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.invalidTextEncoding
        }
        return text
    }

    /// 状态码检查。401 / 403 统一转成 `.unauthorized`。
    static func checkStatus(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(statusCode: response.statusCode)
        }
    }
}

/// 基于 `URLSession` 的最小实现。
///
/// 每次请求都从 Keychain 现读 Token。多一次 Keychain 查询换取"Token 不会被缓存"，
/// 对本项目的请求频率来说完全划算。
///
/// 不引入任何第三方网络库，也不做请求重试 / 刷新 —— 没有验证过的刷新语义就不猜。
final class APIClient: APIClientProtocol {

    /// 本项目所有 Yunxiao 接口统一使用的认证头字段名。
    static let tokenHeaderField = "x-yunxiao-token"

    private let session: URLSession
    private let keychain: any KeychainServiceProtocol
    private let tokenFields: [String]

    init(
        session: URLSession = .shared,
        keychain: any KeychainServiceProtocol = KeychainService(),
        tokenFields: [String] = [APIClient.tokenHeaderField]
    ) {
        self.session = session
        self.keychain = keychain
        self.tokenFields = tokenFields
    }

    /// 只暴露字段名，值固定是占位符 —— 界面展示请求信息时走这里。
    var tokenHeaderFields: [String] { tokenFields }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let authorized = try authorize(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authorized)
        } catch {
            throw APIError.network(Self.shortDescription(of: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (data, http)
    }

    // MARK: - Token 注入

    private func authorize(_ request: URLRequest) throws -> URLRequest {
        let token = try keychain.loadToken()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            throw APIError.missingToken
        }

        var request = request
        for field in tokenFields {
            request.setValue(token, forHTTPHeaderField: field)
        }
        return request
    }

    /// 只保留 `URLError` 的错误码与简短说明。
    ///
    /// 不用 `localizedDescription` 拼接原始错误 —— 它可能带出失败请求的上下文，
    /// 虽然我们的 URL 里从不包含 Token，但错误信息这条路径没有必要冒这个险。
    private static func shortDescription(of error: any Error) -> String {
        guard let urlError = error as? URLError else {
            return String(describing: type(of: error))
        }
        return "URLError \(urlError.code.rawValue)"
    }
}
