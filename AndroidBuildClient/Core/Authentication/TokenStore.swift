import Foundation
import Observation

/// Token 的持有者。
///
/// **Token 不缓存在这里**：需要时向 `KeychainService` 现取。
/// ViewModel 只保存"有没有 Token"这个事实，避免把明文长期留在内存的多个副本里。
@MainActor
@Observable
final class TokenStore {

    /// 当前是否有已保存的 Token。
    ///
    /// 注意：这只表示"Keychain 里有值"，**不代表 Token 有效** ——
    /// 有效性必须通过用户信息接口验证。
    private(set) var hasToken = false

    @ObservationIgnored
    private let keychain: any KeychainServiceProtocol

    init(keychain: any KeychainServiceProtocol = KeychainService()) {
        self.keychain = keychain
    }

    /// 从 Keychain 刷新"是否存在 Token"。
    func refresh() {
        let token = try? keychain.loadToken()
        hasToken = !(token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 保存 Token。空串视为删除。
    func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        try keychain.saveToken(trimmed)
        hasToken = true
    }

    /// 删除 Token 并回到未配置状态。
    func delete() throws {
        try keychain.deleteToken()
        hasToken = false
    }
}
