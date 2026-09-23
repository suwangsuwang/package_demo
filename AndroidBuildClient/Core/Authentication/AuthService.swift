import Foundation

/// Token 认证抽象。
///
/// 本项目**没有传统登录**：没有用户名密码、没有 OAuth、没有 Cookie、没有登录服务器。
/// 用户只提供一个个人 Token，保存进 Keychain，之后所有请求由 `APIClient` 统一注入
/// `x-yunxiao-token`。
protocol AuthServiceProtocol: Sendable {

    /// 保存 Token 后立即验证一次。
    ///
    /// 验证方式：调用用户信息接口。失败时**不保留**刚写入的 Token，
    /// 避免把一个无效 Token 留在 Keychain 里让下次启动再失败一遍。
    ///
    /// - Returns: 用户信息接口返回的 `YunxiaoUser`。
    func saveAndVerify(token: String) async throws -> YunxiaoUser

    /// 用 Keychain 中已有的 Token 验证当前会话。
    ///
    /// Keychain 里有 Token 不等于 Token 有效，所以启动时走这里确认。
    func verifySavedToken() async throws -> YunxiaoUser

    /// 清除 Token。
    func clearToken() throws
}

/// 真实实现。
///
/// 除了用户信息接口之外，这里不做任何认证逻辑 —— Token 的注入统一由 `APIClient` 完成。
struct AuthService: AuthServiceProtocol {

    private let api: any APIClientProtocol
    private let keychain: any KeychainServiceProtocol

    init(
        api: any APIClientProtocol = APIClient(),
        keychain: any KeychainServiceProtocol = KeychainService()
    ) {
        self.api = api
        self.keychain = keychain
    }

    func saveAndVerify(token: String) async throws -> YunxiaoUser {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.missingToken
        }

        try keychain.saveToken(trimmed)

        do {
            return try await fetchCurrentUser()
        } catch {
            // 无效 Token 不留存。清理动作本身失败时不覆盖原始错误。
            try? keychain.deleteToken()
            throw error
        }
    }

    func verifySavedToken() async throws -> YunxiaoUser {
        try await fetchCurrentUser()
    }

    func clearToken() throws {
        try keychain.deleteToken()
    }

    /// 用户信息接口。既是 Token 有效性验证，也是当前用户来源。
    private func fetchCurrentUser() async throws -> YunxiaoUser {
        let request = try URLRequest.yunxiao(
            path: AppConfiguration.Path.currentUser,
            method: "GET"
        )
        return try await api.send(request, decoding: YunxiaoUser.self)
    }
}
