import SwiftUI

/// Build 页面。
///
/// 只做展示与触发：状态来自 `BuildViewModel`，网络细节全在 `FlowService` 里，
/// 这里不拼 URL，也不接触 Token。
///
/// ⚠️ **状态持有者不在这个 View 里**：`viewModel` 来自 `AppModel`，而不是
/// `@State`。因为「Yunxiao 配置」和「打包」是两个互斥的顶层页面，
/// 用 `@State` 的话切走一次 View 就被销毁 —— 正在轮询的 `Task` 被取消、
/// 已拿到的状态与结果全部丢失，切回来只剩一个空白页。
struct BuildView: View {

    @Environment(AppModel.self) private var appModel

    /// 由 `AppModel` 持有，跨页面切换存活。
    private var viewModel: BuildViewModel { appModel.buildViewModel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let user = appModel.currentUser {
                    userLine(user)
                }

                controls

                Divider()

                statusSection

                if let message = viewModel.state.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ⚠️ 闸门是**两个条件**：有本次运行的身份，且流程已经停下。
                //
                // 只看 `currentBuildRun != nil` 是不够的 —— 触发一成功它就有值了，
                // 而那时服务端上的运行还在 RUNNING。`BuildResultView` 是快照式的
                // （挂载时打一次接口，之后不再重问），先挂上去就把那个
                // `RUNNING` + 空产物快照定了型，界面上表现为"记录里已经跑完、
                // 结果页却一直构建中"。运行期间这一块不出现 —— 实时状态在
                // 上面的 `statusSection` 那一行里，它跟着轮询更新。
                //
                // 不能收窄成"成功才给看"：`.failed` 同样要能看到结果页
                // （失败 / 取消 / 超时三种收场都落在它上面）。
                if viewModel.currentBuildRunHasStopped, let run = viewModel.currentBuildRun {
                    Divider()

                    // 结果区块**只有这一处实现**：`BuildResultView` 自己带着
                    // 它的 ViewModel 去问服务端"#\(run.pipelineRunId) 的结果是什么"，
                    // 当前构建页只负责把"看哪一次运行"告诉它。
                    //
                    // 传的是 `run` 里存的那一份身份（`pipelineId + pipelineRunId`），
                    // **不是**界面上此刻选中的环境 —— 环境是发起构建时的用户配置，
                    // 而这条运行当年跑在哪条流水线上已经是既成事实。
                    //
                    // ⚠️ `id` 是必须的，不是优化：`BuildResultView` 的
                    // `@State viewModel` 只在**视图身份变化**时才重建，而 `.task`
                    // 也只在身份变化时才重跑。不加 `id` 的话，第二次打包会复用
                    // 同一个 ViewModel —— 屏幕上一直显示**上一次**那条运行的结果，
                    // 看起来还完全正常。运行 ID 是服务端分配的、单调递增的，
                    // 一次运行对应一个身份，拿它做 `id` 就够。
                    //
                    // 上面那道闸门与这里的 `.id` 是配合关系而不是重复：闸门让"第一次
                    // 挂载"发生在流程停止之后（`.task` 才会跑到终态快照），`.id` 让
                    // 下一轮打包换成新身份（`.task` 才会为新的那次运行重跑）。
                    BuildResultView(
                        pipelineRunId: run.pipelineRunId,
                        pipelineId: run.pipelineId
                    )
                    .id(run.pipelineRunId)
                }

                if let message = viewModel.loadErrorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 历史区块整个搬到了 `HistoryView`。这里只负责把数据递过去 ——
                // 加载仍然由 `BuildViewModel` 负责（`load()` / `refreshHistory()`），
                // 本页继续是历史数据的唯一拥有者，`HistoryView` 只是展示。
                HistoryView(
                    runs: viewModel.history,
                    isLoading: viewModel.isLoadingHistory
                )

                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            // 从配置页切回来时这个 View 会重新出现，但状态持有者在 AppModel 上，
            // 所以这里只补第一次加载 —— 否则每次切回来都会重打两个接口，
            // 还会把页面上正在展示的错误信息悄悄清掉。
            await viewModel.loadIfNeeded()
        }
        // 历史记录点进来的目的地。**声明在这里，不在 `HistoryView` 里** ——
        // 它表达的是「打开某一次运行的结果」，属于 Build 工作区内部的一次页面
        // 跳转，与「这条记录出现在列表第几行」无关。挂在 `BuildView` 上，
        // 它同时也是 `RootView` 那个 `NavigationStack` 的根视图。
        //
        // ⚠️ **不加 `.id(...)`。** 下面那个 `BuildResultView` 的身份由
        // `NavigationLink(value:)` 传进来的 `BuildRunIdentity` 决定：换一条记录
        // 就是换一个导航元素，SwiftUI 会为它建一个新的视图身份，`@State`
        // 的 `BuildResultViewModel` 随身份新建、`.task` 也随之重跑。
        // 当前构建那条路径不一样 —— 它在 `body` 里的位置固定，必须靠
        // `.id(run.pipelineRunId)` 才能打断身份，那里的 `id` 不能删。
        .navigationDestination(for: BuildRunIdentity.self) { identity in
            BuildResultView(
                pipelineRunId: identity.pipelineRunId,
                pipelineId: identity.pipelineId
            )
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.pipelineInfo?.name ?? "流水线打包")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Yunxiao 配置") {
                appModel.route = .tokenSetup
            }
            .buttonStyle(.link)
        }
    }

    private var subtitle: String {
        guard let info = viewModel.pipelineInfo else {
            return "触发流水线打包，完成后展示 APK 下载地址与二维码。"
        }
        // 版本取不到就不显示那一段 —— 展示字段缺失不该在标题下面留个空括号。
        guard let version = info.version else { return "流水线 ID \(info.id)" }
        return "流水线 ID \(info.id) · 版本 \(version)"
    }

    private func userLine(_ user: YunxiaoUser) -> some View {
        Label("当前用户：\(user.name)（\(user.email)）", systemImage: "person.crop.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - 操作

    private var controls: some View {
        // ⚠️ 这四个控件在窄窗口下排不进一行。两个 Picker 都带 `.fixedSize()`，
        // 不服从压缩，`HStack` 于是把宽度亏空全部转嫁给后面的 Button —— 实测窗口
        // 560 时 `开始打包` 被压成 23×24、`刷新分支` 被压成 31×24（固有宽度分别是
        // 76 与 97），整列的内在宽度涨到 796。macOS 的 `ScrollView` 不横向滚动，
        // 超出视口的部分直接被裁掉，右侧控件就看不见了。
        //
        // 用 `ViewThatFits` 按**可用宽度**自动降级，而不是自己读窗口宽度：
        //   宽窗口   → 一行（与改动前逐字一致）
        //   窄窗口   → 两行（分支独占第一行）
        //   再窄一点 → 三行（460 且正在构建时，第二行还多一个「取消」）
        //
        // 三份候选里的控件是**刻意重复**的：`ViewThatFits` 要求每个候选自身完整，
        // 而把叶子控件抽出去会把「一行 / 两行 / 三行」揉进一层抽象，反而不容易
        // 一眼看出哪一档长什么样。
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                wideControls
                narrowControls
                narrowestControls
            }

            branchNotice
        }
    }

    /// 宽版：与改动前**完全一致**的一行布局 `分支 | 环境 | 开始打包 | 刷新分支`。
    private var wideControls: some View {
        @Bindable var viewModel = viewModel

        return HStack(spacing: 12) {
            // 两个 Picker 是**并列且独立**的，不是"环境决定分支"的联动关系。
            // 分支决定 runningBranchs 的取值，环境决定 envs 的取值，
            // 允许「代码分支 test + 构建环境 release」这类交叉组合。
            branchControl

            Picker("构建环境", selection: $viewModel.environment) {
                ForEach(AppConfiguration.Environment.allCases) { environment in
                    Text(environment.displayName).tag(environment)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(viewModel.isRunning)
            .help("触发时作为 envs.env 的取值。与代码分支相互独立。")
            .onChange(of: viewModel.environment) {
                viewModel.environmentDidChange()
            }

            Button("开始打包") {
                viewModel.startBuild()
            }
            .keyboardShortcut(.defaultAction)
            // 分支没确定就不允许触发：`selectedBranch` 是触发请求体里
            // `runningBranchs` 取值的唯一来源，为空时点下去只会构建出另一个
            // 分支的包，而界面上一路显示"构建成功"。
            .disabled(
                viewModel.isRunning
                    || viewModel.branches.isEmpty
                    || viewModel.selectedBranch == nil
            )

            if viewModel.isRunning {
                Button("取消") {
                    viewModel.cancel()
                }
            } else if viewModel.state != .idle {
                Button("重新打包") {
                    viewModel.startBuild()
                }
            }

            // 刷新分支列表：重走「流水线 → 仓库列表 → 匹配 → 分支列表」。
            // 拿不到分支时它是**唯一**的恢复入口（此时开始打包是禁用的），
            // 所以无论成功失败都留着，只在加载中禁用。
            Button {
                Task { await viewModel.loadBranches() }
            } label: {
                Label("刷新分支", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingBranches || viewModel.isRunning)
            .help("重新从 Codeup 获取该流水线所绑定仓库的分支列表。")

            Spacer()
        }
    }

    /// 窄版：两行。
    ///
    /// 第一行只有分支 Picker —— 当前选中的分支名是这个 App 最该看清的值，
    /// 宁可占一整行也不让它被截断。其余三个控件放第二行。
    ///
    /// 第二行里的控件与 `wideControls` 逐字相同（文案 / action / `disabled`
    /// 条件 / `help` 都没变），只是换了个位置。
    private var narrowControls: some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                branchControl

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("构建环境", selection: $viewModel.environment) {
                    ForEach(AppConfiguration.Environment.allCases) { environment in
                        Text(environment.displayName).tag(environment)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(viewModel.isRunning)
                .help("触发时作为 envs.env 的取值。与代码分支相互独立。")
                .onChange(of: viewModel.environment) {
                    viewModel.environmentDidChange()
                }

                Button("开始打包") {
                    viewModel.startBuild()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    viewModel.isRunning
                        || viewModel.branches.isEmpty
                        || viewModel.selectedBranch == nil
                )

                if viewModel.isRunning {
                    Button("取消") {
                        viewModel.cancel()
                    }
                } else if viewModel.state != .idle {
                    Button("重新打包") {
                        viewModel.startBuild()
                    }
                }

                Button {
                    Task { await viewModel.loadBranches() }
                } label: {
                    Label("刷新分支", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingBranches || viewModel.isRunning)
                .help("重新从 Codeup 获取该流水线所绑定仓库的分支列表。")

                Spacer()
            }
        }
    }

    /// 最窄版：三行。
    ///
    /// 460 宽时可用宽度只有 404，而「取消」出现后第二行的固有宽度是
    /// `162.5 + 12 + 76 + 12 + 50 + 12 + 97 ≈ 421`，两行仍然放不下，
    /// 所以把「刷新分支」再单独挪到第三行。
    private var narrowestControls: some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                branchControl

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("构建环境", selection: $viewModel.environment) {
                    ForEach(AppConfiguration.Environment.allCases) { environment in
                        Text(environment.displayName).tag(environment)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(viewModel.isRunning)
                .help("触发时作为 envs.env 的取值。与代码分支相互独立。")
                .onChange(of: viewModel.environment) {
                    viewModel.environmentDidChange()
                }

                Button("开始打包") {
                    viewModel.startBuild()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    viewModel.isRunning
                        || viewModel.branches.isEmpty
                        || viewModel.selectedBranch == nil
                )

                if viewModel.isRunning {
                    Button("取消") {
                        viewModel.cancel()
                    }
                } else if viewModel.state != .idle {
                    Button("重新打包") {
                        viewModel.startBuild()
                    }
                }

                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.loadBranches() }
                } label: {
                    Label("刷新分支", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingBranches || viewModel.isRunning)
                .help("重新从 Codeup 获取该流水线所绑定仓库的分支列表。")

                Spacer()
            }
        }
    }

    /// 分支选择控件。三种状态互斥：加载中 / 加载失败 / 已就绪。
    @ViewBuilder
    private var branchControl: some View {
        @Bindable var viewModel = viewModel

        if viewModel.isLoadingBranches {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在获取代码分支...")
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.branches.isEmpty {
            // 失败时不留一个空 Picker —— 空菜单看起来像"这个仓库没有分支"。
            // 具体原因在下面的 `branchNotice` 里。
            Text("代码分支不可用")
                .foregroundStyle(.secondary)
        } else {
            // 分支列表**全部来自接口**，没有任何一个取值是写死的。
            // 显示 `name` 原文（就是 git 分支名，也是请求体里实际发出去的值），
            // 写成"Test 分支"之类的话，界面上的字和线上分支名就对不上了。
            // 排序（默认分支在前）在 ViewModel 里做，这里保持响应顺序。
            Picker("代码分支", selection: $viewModel.selectedBranch) {
                ForEach(viewModel.branches) { branch in
                    Text(branch.name).tag(String?.some(branch.name))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(viewModel.isRunning)
            .help("触发时作为 runningBranchs 的取值。与构建环境相互独立。")
        }
    }

    /// 分支加载的提示行。加载中不显示（控件本身就是提示），
    /// 成功且无错误时也不显示 —— 这里只在**出了问题**时说话。
    @ViewBuilder
    private var branchNotice: some View {
        if let error = viewModel.branchError {
            VStack(alignment: .leading, spacing: 2) {
                Label("无法获取代码分支，请检查 Token 权限或网络连接。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                // 具体原因单独一行。它来自接口错误，不含 Token 与请求头，
                // 而且正是排查时需要的那句话（"找不到仓库""HTTP 404"…）。
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if viewModel.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(viewModel.state.displayText)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            // 服务端原文单独一行原样展示。刻意不做中文转写 ——
            // "正在执行流水线"是客户端的话，用户没法据此判断服务端究竟回了什么；
            // `status` 原文才是可核对的事实。
            if let serverStatus = viewModel.state.serverStatus {
                Text("服务端返回 status：\(serverStatus)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 辅助
    //
    // 原来这里的 `dateText` / `durationText` / `color(for:)` 三个私有辅助
    // **只服务于历史行**，已随历史区块一起搬进 `HistoryView.swift`。
}