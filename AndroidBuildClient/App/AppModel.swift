import Foundation
import Observation

/// App 级状态：顶层导航 + Token 是否存在 + 打包页状态持有者。
///
/// `buildViewModel` 挂在这里而不是 `BuildView` 内部，是因为「Yunxiao 配置」
/// 与「打包」是两个互斥的顶层页面（`RootView` 是 `switch`），切走时
/// `BuildView` 连同它的 `@State` 一起被销毁：
///
/// - 正在轮询的任务会随 `BuildViewModel` 一起 deinit，`Task` 随之取消；
/// - 已经拿到的状态、历史记录、解析出的 APK 地址全部丢失。
///
/// 用户看到的现象就是"进配置页看一眼，回来打包就没了"。把持有者提到
/// `AppModel` 这一层，页面切来切去都不影响后台的轮询。
@MainActor
@Observable
final class AppModel {

    /// 当前展示的顶层页面。
    var route: AppRoute = .tokenSetup

    /// Token 存在性。**不保存 Token 明文**。
    @ObservationIgnored
    let tokenStore: TokenStore

    /// 打包页的状态持有者。**与页面生命周期解耦** —— 见类型注释。
    @ObservationIgnored
    let buildViewModel = BuildViewModel()

    /// 当前 Token 对应的用户。启动验证或手动验证成功后写入，仅用于展示。
    private(set) var currentUser: YunxiaoUser?

    /// 启动时的 Token 校验状态。
    ///
    /// 注意：Keychain 里有 Token **不代表 Token 有效**，
    /// 因此启动时必须真的调用一次用户信息接口才能进入打包页。
    private(set) var bootstrap: Bootstrap = .idle

    @ObservationIgnored
    private let authService: any AuthServiceProtocol

    init(
        tokenStore: TokenStore = TokenStore(),
        authService: any AuthServiceProtocol = AuthService()
    ) {
        self.tokenStore = tokenStore
        self.authService = authService
    }

    /// 启动流程：读 Keychain → 有 Token 就验证 → 决定落在哪个页面。
    func bootstrapToken() async {
        tokenStore.refresh()

        guard tokenStore.hasToken else {
            bootstrap = .needsToken
            route = .tokenSetup
            return
        }

        bootstrap = .verifying
        do {
            currentUser = try await authService.verifySavedToken()
            bootstrap = .verified
            route = .build
        } catch {
            // Token 存在但无效：留在 Token 页面让用户重新填写。
            // 不自动删除 —— 用户可能只是网络不通，删掉会让他重新粘贴一遍。
            currentUser = nil
            bootstrap = .invalidToken(Self.message(for: error))
            route = .tokenSetup
        }
    }

    /// 记录刚验证通过的用户（Token 页面保存成功后调用）。
    func setCurrentUser(_ user: YunxiaoUser?) {
        currentUser = user
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

/// 启动校验状态。只用于界面提示，不参与业务判断。
enum Bootstrap: Sendable, Equatable {
    case idle
    /// Keychain 里没有 Token。
    case needsToken
    case verifying
    case verified
    /// Token 存在但验证失败，附带原因。
    case invalidToken(String)
}

/// 顶层路由。
///
/// 只区分两个页面 —— 不引入 Router / Coordinator。
enum AppRoute: Sendable, Equatable {
    case tokenSetup
    case build
}
