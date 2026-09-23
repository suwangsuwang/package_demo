import Foundation
import Observation

/// Token 配置页的状态持有者。
///
/// 只负责界面状态与调用顺序 —— 验证逻辑在 `AuthService`，Token 存储走 Keychain。
@MainActor
@Observable
final class TokenSetupViewModel {

    /// 输入框内容。仅存在于内存中，不落盘，也不写日志。
    var input = ""

    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// 验证成功后的用户信息。
    private(set) var user: YunxiaoUser?

    @ObservationIgnored
    private let authService: any AuthServiceProtocol
    @ObservationIgnored
    private let tokenStore: TokenStore

    init(
        authService: any AuthServiceProtocol = AuthService(),
        tokenStore: TokenStore
    ) {
        self.authService = authService
        self.tokenStore = tokenStore
    }

    /// 输入框有内容且不在请求中即可提交。
    var canSubmit: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    /// 保存并验证 Token。成功返回 `true`，由调用方决定是否跳转。
    func save() async -> Bool {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let user = try await authService.saveAndVerify(token: token)
            apply(user)
            // 保存成功后不再需要明文留在输入框里。
            input = ""
            return true
        } catch {
            errorMessage = Self.message(for: error)
            tokenStore.refresh()
            apply(nil)
            return false
        }
    }

    /// 用 Keychain 中已有的 Token 验证。成功返回 `true`。
    func verifySavedToken() async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let user = try await authService.verifySavedToken()
            apply(user)
            return true
        } catch {
            errorMessage = Self.message(for: error)
            apply(nil)
            return false
        }
    }

    /// 删除 Keychain 中的 Token。
    func deleteToken() {
        do {
            try tokenStore.delete()
            input = ""
            errorMessage = nil
            apply(nil)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// 清除错误提示（例如用户开始重新输入时）。
    func clearError() {
        errorMessage = nil
    }

    private func apply(_ user: YunxiaoUser?) {
        tokenStore.refresh()
        self.user = user
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
