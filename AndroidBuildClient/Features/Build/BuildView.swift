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

                historySection

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
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
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

            branchNotice
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

    // MARK: - 历史打包记录

    /// 历史记录列表。
    ///
    /// 展示的字段全部来自历史记录接口的原文：`pipelineRunId` / `status` /
    /// `triggerMode` / `startTime` / `endTime` / `creatorAccountId`。
    /// 只有「耗时」是本地算出来的（`endTime - startTime`），其余不做任何加工 ——
    /// 尤其是 `status`，直接显示服务端原文，而不是翻译成中文后再让用户去猜。
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(spacing: 8) {
                Text("最近打包记录").font(.headline)
                if viewModel.isLoadingHistory {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if viewModel.history.isEmpty {
                Text(viewModel.isLoadingHistory ? "正在加载…" : "暂无记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 只展示最近 10 条，不做分页。
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.history.prefix(10)) { run in
                        historyRow(run)
                    }
                }
            }
        }
    }

    private func historyRow(_ run: PipelineRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("#\(run.pipelineRunId)")
                .font(.callout.monospaced())
                .frame(width: 60, alignment: .leading)

            // 服务端状态原文，不是归类后的中文。
            Text(run.status)
                .font(.callout.monospaced())
                .foregroundStyle(color(for: run.runStatus))
                .frame(width: 90, alignment: .leading)

            Text(run.trigger.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(Self.dateText(run.startTime))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(run.creatorID ?? "—")
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(run.creatorID ?? "该记录没有触发者账号 ID")

            Spacer(minLength: 12)

            if let startTime = run.startTime, let endTime = run.endTime {
                Text(Self.durationText(from: startTime, to: endTime))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if run.runStatus == .running {
                Text("进行中")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 辅助

    private func color(for status: PipelineRunStatus) -> Color {
        switch status {
        case .succeeded: .green
        case .failed: .red
        case .canceled, .running, .unknown: .secondary
        }
    }

    /// 毫秒时间戳 → 本地时间文本。时间戳缺失时（运行详情接口不返回起始时间）显示占位符。
    private static func dateText(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "—" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return date.formatted(date: .numeric, time: .shortened)
    }

    private static func durationText(from start: Int64, to end: Int64) -> String {
        let seconds = max(0, end - start) / 1000
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}
