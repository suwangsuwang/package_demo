import SwiftUI

/// 「某一次运行的构建结果」详情页。
///
/// 它只认两样东西：一个 `pipelineRunId`、一个 `pipelineId`。其余全部来自
/// `BuildResultViewModel` —— 这个 View 不拼接口、不碰 Token、不解析日志。
///
/// ⚠️ **这是全项目唯一的结果展示实现。** 两个入口都接在它上面：当前构建
/// （`BuildView` 在 `currentBuildRunHasStopped` 时渲染）与历史记录
/// （`BuildView` 的 `navigationDestination` 渲染）。它之所以是"唯一一处"
/// 而不是"当前构建一处、历史各处一处"：这两条路径要展示的是同一件东西
/// （某一次运行的结果），拆成两个 View 只会让它们慢慢长歪，最后同一个 Run
/// 在两条路径下显示得不一样。
///
/// ⚠️ **调用方必须给它一个随运行变化的视图身份。** 两条入口各自做到这点，
/// 但**做法不同，不能互换**：
///
/// - 当前构建用 `.id(run.pipelineRunId)`。它在这个 View 里的位置是固定的，
///   SwiftUI 的身份按"类型 + 位置"算，两次打包之间身份相同 —— 不加 `id`
///   的话 `@State` 的 `BuildResultViewModel` 会被复用，第二次打包屏幕
///   显示的仍是上一次那条运行的结果，而且看起来完全正常。
/// - 历史记录**不加 `.id`**：身份由 `NavigationLink(value:)` 传进来的
///   `BuildRunIdentity` 决定。换一条记录就是换一个导航元素，SwiftUI 自然
///   建出新的身份。给它再套一个 `.id` 是多余的第二套身份机制。
///
/// 两条路径的 `BuildResultViewModel` **各自独立**，不共享实例。
struct BuildResultView: View {

    /// 要看的那一次运行。
    let pipelineRunId: Int

    /// 这条运行所属的**流水线 ID**。与 `pipelineRunId` 一起构成这一次运行的完整身份。
    ///
    /// **只用于调用 `BuildService`**（它标明这条运行属于哪条流水线），
    /// 不是"这次构建结果"的字段，界面上不展示它。
    let pipelineId: String

    @State private var viewModel = BuildResultViewModel()

    /// 二维码重试计数。只用于 `.id(...)`：`AsyncImage` 没有重试 API，
    /// 换一个视图身份是让它重新发一次图片请求的唯一办法。
    ///
    /// 它不是业务状态，也不需要被测试断言，因此留在 View 里 ——
    /// 放进 ViewModel 只会多一个测不了又必须维护的字段。
    @State private var qrRetryID = 0

    /// 「下载 APK」打开失败（`URLLauncher.open` 返回 `false`）时置为 `true`。
    @State private var openFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                content

                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            // ViewModel 不保存 Task；视图消失时 SwiftUI 取消这个任务，
            // `load` 里的 `defer` 会把 isLoading 收干净。
            await viewModel.load(
                pipelineRunId: pipelineRunId,
                pipelineId: pipelineId
            )
        }
        .alert("无法打开链接", isPresented: $openFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("系统没能打开这个 APK 地址。可以改用「复制地址」，粘贴到浏览器里再试。")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        Text("构建结果")
            .font(.largeTitle.weight(.semibold))
    }

    // MARK: - 页面状态

    /// 顺序固定：加载中 → 加载失败 → 有结果。三者互斥。
    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            loadingSection
        } else if let message = viewModel.errorMessage {
            errorSection(message)
        } else if viewModel.result != nil {
            resultSection
        }
    }

    private var loadingSection: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在获取构建结果…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 加载失败。
    ///
    /// 这一屏说的是**取不到结果**，与"构建失败"（`status = FAIL`）完全是两回事：
    /// 后者是取到了结果、结果是失败。措辞上必须分得开。
    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("无法获取该构建的结果", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("该构建可能已经不存在，或者云效暂时无法访问。")
                .font(.callout)
                .foregroundStyle(.secondary)

            // 具体原因来自错误类型自己的 errorDescription，不含请求头 / Token / 配置内容。
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button("重试") {
                Task {
                    await viewModel.load(
                        pipelineRunId: pipelineRunId,
                        pipelineId: pipelineId
                    )
                }
            }
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusSection

            Divider()

            infoSection

            if let artifacts = viewModel.visibleArtifacts {
                artifactsSection(artifacts)
            } else if viewModel.result?.isSuccessful == true {
                // 取到了结果、服务端原文就是 SUCCESS，但两个产物标记都没解析到。
                // 这是**成功态的一种**，不是失败 —— 详见 `BuildResultViewModel.visibleArtifacts`。
                missingArtifactsNotice
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("状态").font(.headline)

            if let runStatus = viewModel.runStatus {
                statusHeadline(runStatus)

                if let text = serverStatusText(runStatus) {
                    Text(text)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 五种状态各自的措辞。**认不出的状态值既不是成功、也不是失败**，
    /// 它有自己的那一行文案。
    @ViewBuilder
    private func statusHeadline(_ status: PipelineRunStatus) -> some View {
        switch status {
        case .running:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("构建中").font(.title3.weight(.semibold))
                }

                // ⚠️ **这个刷新按钮是给历史入口用的，不是装饰。**
                //
                // 本页是**快照式**的：`.task` 在视图身份建立时打一次接口，
                // 之后不再重问。当前构建那条路径由 `currentBuildRunHasStopped`
                // 保证"挂载时已经终态"，所以永远走不到这个分支；但历史记录
                // **可能是 `RUNNING`**（刚触发的那一次就在列表里，用户完全
                // 可以在构建过程中点进来）。没有这个按钮的话，那条页面会
                // 永久停在"构建中"，哪怕服务端早已跑完。
                //
                // 刻意**不做后台轮询**：为了一个极少数的 RUNNING 历史记录引入
                // 持续请求，会让生命周期复杂很多。这是一次显式的重问。
                //
                // 复用 `load` 本身 —— 它已经是"重新请求并覆盖旧结果"的语义，
                // 这里不复制任何取数逻辑。
                Button("刷新") {
                    Task {
                        await viewModel.load(
                            pipelineRunId: pipelineRunId,
                            pipelineId: pipelineId
                        )
                    }
                }
            }
        case .succeeded:
            Label("构建成功", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Label("构建失败", systemImage: "xmark.octagon.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
        case .canceled:
            Label("构建已取消", systemImage: "slash.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        case .unknown:
            Label("未知构建状态", systemImage: "questionmark.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// 状态原文那一行。
    ///
    /// 一般状态直接显示服务端原文（用户要能核对服务端究竟回了什么）；
    /// `unknown` 改用 `PipelineRunStatus.displayText` —— 它给出的
    /// 「流水线状态：X（未识别的状态值）」本来就带着原文，
    /// 不必在同一个状态值上写两行。
    private func serverStatusText(_ status: PipelineRunStatus) -> String? {
        if case .unknown = status { return status.displayText }
        guard let raw = viewModel.result?.status else { return nil }
        return "服务端返回 status：\(raw)"
    }

    // MARK: - 基本信息

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ⚠️ 这里**不显示分支 / 环境**。「运行详情」与「历史记录」两个接口
            // 都不返回它们，客户端也没有别的可靠来源 —— 补一个上去只是把
            // 客户端自己的猜测当成事实展示。
            infoRow("Pipeline Run", "#\(viewModel.result?.pipelineRunId ?? pipelineRunId)")
            infoRow("构建时间", Self.dateText(viewModel.result?.createdAt))
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }

    // MARK: - 产物

    /// APK 与二维码**各自独立**：两个地址是两个独立的 Optional，
    /// 有其中一个就该显示其中一个，不因为另一个缺失而整块隐藏。
    private func artifactsSection(_ artifacts: BuildArtifacts) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Divider()
            apkBlock(artifacts.apkURL)
            qrCodeBlock(artifacts.qrCodeURL)
        }
    }

    @ViewBuilder
    private func apkBlock(_ apkURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APK").font(.headline)

            if let apkURL {
                Text(apkURL.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("下载 APK") {
                        // 打开失败只提示这一次，**不改动构建状态** ——
                        // 构建仍然是成功的，只是这个链接这次没打开。
                        if !URLLauncher.open(apkURL) {
                            openFailed = true
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    // `copyToPasteboard` 没有返回成功/失败的信号，
                    // 因此这里不做"复制失败"的判断 —— 编造一个永远不会出现的
                    // 错误提示，比没有提示更糟。
                    Button("复制地址") {
                        URLLauncher.copyToPasteboard(apkURL.absoluteString)
                    }
                }
            } else {
                Text("本次运行没有返回 APK 地址")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func qrCodeBlock(_ qrCodeURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("二维码").font(.headline)

            if let qrCodeURL {
                // 二维码是打包脚本生成的静态图片，客户端只做展示，不重新生成。
                AsyncImage(url: qrCodeURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            // 固定 180×180：图片原始尺寸千差万别，不钉死会把这一屏撑开。
                            .frame(width: 180, height: 180)
                            .background(.quaternary, in: .rect(cornerRadius: 8))
                    case .failure:
                        // 图片加载失败**只影响这块图片**：上面的构建状态、
                        // 旁边的 APK 按钮全部照常。两者本来就是独立的两件事。
                        VStack(spacing: 8) {
                            Label("二维码加载失败", systemImage: "photo.badge.exclamationmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("重试") { qrRetryID += 1 }
                                .controlSize(.small)
                        }
                        .frame(width: 180, height: 180)
                    default:
                        ProgressView()
                            .frame(width: 180, height: 180)
                    }
                }
                // 换一个身份 → `AsyncImage` 重新发一次图片请求。
                .id(qrRetryID)

                Text(qrCodeURL.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本次运行没有返回二维码地址")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 「构建成功但没有产物」的提示。
    ///
    /// 这是**成功态的一种**，不是错误态：服务端返回的 `status` 原文就是 `SUCCESS`。
    /// 出现它的典型原因是打包脚本不再输出产物标记 —— 那是脚本侧的变化，
    /// 重新触发一次打包不会让它变好，所以文案里要给出可执行的方向。
    /// 这段现在是**唯一一份** —— `BuildView` 那份同类提示已随旧结果区块一起删除。
    private var missingArtifactsNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("构建成功，但没有找到 APK/二维码地址", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(
                "流水线状态为成功，但日志中未出现"
                    + "「\(AppConfiguration.LogMarker.uploadCompleted)」或"
                    + "「\(AppConfiguration.LogMarker.qrCodeAddress)」标记。"
                    + "请确认打包脚本仍然输出这两个标记。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 辅助

    /// 毫秒时间戳 → 本地时间文本。
    ///
    /// 时间戳缺失时显示占位符，**不用当前本地时间兜底** —— 那会让一条三天前的
    /// 记录显示成刚刚构建的，而且看不出是编造的。
    ///
    /// 与 `BuildView.dateText` 是同一套规则（那一份是 `private`，够不着）。
    private static func dateText(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "—" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return date.formatted(date: .numeric, time: .shortened)
    }
}
