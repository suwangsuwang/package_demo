import SwiftUI

/// Token 配置页面（「Yunxiao 配置」）。
///
/// 本项目没有传统登录：用户只提供个人 Yunxiao Token，
/// 保存进 Keychain 后立刻用用户信息接口验证一次。
struct TokenSetupView: View {

    @Environment(AppModel.self) private var appModel

    @State private var viewModel: TokenSetupViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            if let viewModel {
                content(viewModel)
            } else {
                ProgressView().controlSize(.small)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // ViewModel 需要 TokenStore，而 TokenStore 由 AppModel 持有。
            if viewModel == nil {
                viewModel = TokenSetupViewModel(tokenStore: appModel.tokenStore)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Yunxiao 配置")
                .font(.largeTitle.weight(.semibold))
            Text("填入个人 Token 后即可触发 Android 打包。Token 只保存在本机 Keychain。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 主体

    private func content(_ viewModel: TokenSetupViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if appModel.tokenStore.hasToken {
                savedTokenSection(viewModel)
            } else {
                inputSection(viewModel)
            }

            if viewModel.isWorking || appModel.bootstrap == .verifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在验证 Token…").foregroundStyle(.secondary)
                }
            }

            if let message = errorMessage(viewModel) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let user = viewModel.user ?? appModel.currentUser {
                userSection(user)
            }
        }
    }

    private func inputSection(_ viewModel: TokenSetupViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("个人 Token")
                .font(.callout)
                .foregroundStyle(.secondary)

            // SecureField：Token 不以明文显示。
            SecureField("粘贴个人 Token", text: $viewModel.input)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isWorking)
                .onSubmit { submit(viewModel) }

            Button("保存并验证") {
                submit(viewModel)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canSubmit)
        }
    }

    private func savedTokenSection(_ viewModel: TokenSetupViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Token 已保存在 Keychain", systemImage: "checkmark.seal")
                .font(.callout)

            // 只展示占位符，不展示 Token 的任何字符。
            HStack(spacing: 6) {
                Text("• • • • • • • • • • • •")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Text("（不显示明文）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("更换 Token") {
                    viewModel.deleteToken()
                    appModel.setCurrentUser(nil)
                }
                Button("删除 Token", role: .destructive) {
                    viewModel.deleteToken()
                    appModel.setCurrentUser(nil)
                }
                Button("重新验证") {
                    Task { await verify(viewModel) }
                }
                .disabled(viewModel.isWorking)
            }
        }
    }

    private func userSection(_ user: YunxiaoUser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("Token 有效", systemImage: "checkmark.circle")
                .foregroundStyle(.green)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("用户", user.name)
                row("邮箱", user.email)
                if !user.lastOrganization.isEmpty {
                    row("组织", user.lastOrganization)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Button("进入打包页面") {
                appModel.route = .build
            }
            .disabled(!appModel.tokenStore.hasToken)

            Text("Token 仅保存在本机 Keychain，不会写入源码、配置文件或日志。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 动作

    private func submit(_ viewModel: TokenSetupViewModel) {
        Task {
            if await viewModel.save() {
                appModel.setCurrentUser(viewModel.user)
                appModel.route = .build
            }
        }
    }

    private func verify(_ viewModel: TokenSetupViewModel) async {
        if await viewModel.verifySavedToken() {
            appModel.setCurrentUser(viewModel.user)
            appModel.route = .build
        }
    }

    /// 页面内错误优先，其次是启动时的校验结果。
    private func errorMessage(_ viewModel: TokenSetupViewModel) -> String? {
        if let message = viewModel.errorMessage { return message }
        if case .invalidToken(let message) = appModel.bootstrap { return message }
        return nil
    }
}
