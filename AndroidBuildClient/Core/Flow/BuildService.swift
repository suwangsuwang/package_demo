import Foundation

/// 取「某一次运行的构建结果」的**唯一入口**。
///
/// 整个 App 里只有这一个地方知道 APK / 二维码是怎么找到的。它内部串起了
/// 一整条 Yunxiao 内部细节：
/// ```
/// 运行详情（状态 / 开始时间 / jobId）
///   → 该 Job 的步骤列表（按名字定位「执行命令」→ stepIndex / buildId）
///   → 该步骤的整段日志
///   → BuildLogParser 解析出 apkURL / qrCodeURL
/// ```
/// 这些中间量（`jobId` / `stepIndex` / `buildId` / `offset` / `limit`）
/// **全部留在这层的下面**：`BuildViewModel` 与 View 都不该见到它们，
/// 否则"换个接口、换个位置找产物"就要改好几个文件。
protocol BuildServiceProtocol: Sendable {
    /// 取本次运行的构建结果。
    ///
    /// - Parameters:
    ///   - pipelineRunId: 本次运行的 ID。来自触发接口的响应体。
    ///   - pipelineId: **这条运行所属的流水线 ID**。
    ///
    ///     ⚠️ 这两个 ID 是一对，描述的是同一件既成事实 ——「**哪条流水线上的哪一次运行**」。
    ///     下面那些内部 ID（`jobId` / `stepIndex` / `buildId`）全部由接口调用链
    ///     动态取得，没有一个写死；但 `pipelineId` **必须由调用方给出**：
    ///     它没法从 `pipelineRunId` 推出来，而"此刻界面上选的是哪个环境"
    ///     与这次运行当年跑在哪条流水线上是两回事 —— 用后者推前者，
    ///     在环境与流水线不是一一对应时会静默地问到**另一条流水线**上。
    func fetchBuildResult(
        pipelineRunId: Int,
        pipelineId: String
    ) async throws -> BuildResult
}

// MARK: - 真实实现

/// 真实实现：编排 `FlowService` 的三次读 + 一次日志解析。
///
/// 它自己**不做 HTTP、不拼路径**（那是 `FlowService` 的职责），
/// 也不解析日志文本（那是 `BuildLogParser` 的职责）——
/// 只负责"按什么顺序问什么、拿到什么算数"。
struct BuildService: BuildServiceProtocol {

    private let flowService: any FlowServiceProtocol
    private let parser: any BuildLogParsing
    /// 找产物标记时的重试节奏。生产用 `.standard`，测试注入毫秒级参数。
    private let resultParsing: AppConfiguration.ResultParsing

    init(
        flowService: any FlowServiceProtocol = FlowService(),
        parser: any BuildLogParsing = BuildLogParser(),
        resultParsing: AppConfiguration.ResultParsing = .standard
    ) {
        self.flowService = flowService
        self.parser = parser
        self.resultParsing = resultParsing
    }

    func fetchBuildResult(
        pipelineRunId: Int,
        pipelineId: String
    ) async throws -> BuildResult {
        // API 6a：运行详情。状态、开始时间、jobId 都在这一份响应里，
        // 因此**只打一次**，不再为"取 jobId"单独重打一次。
        let head = try await flowService.fetchRunHead(
            pipelineId: pipelineId,
            pipelineRunId: pipelineRunId
        )
        try Task.checkCancellation()

        let status = PipelineRunStatus(rawStatus: head.status)

        // ⚠️ **只有成功终态才去找产物。**
        //
        // 失败 / 取消 / 认不出的状态都直接返回空产物，不去读日志。两个理由：
        // 1. 「未知状态绝不能被当成成功」—— 认不出的状态值如果继续往下走，
        //    日志里恰好有上一次遗留的标记，界面上就会出现一个假的 APK 地址。
        // 2. 失败与取消的运行本来就不会输出产物标记，多打两个接口只是白等。
        //
        // 这里**不看 `runStatus == .running`**：调用方（当前构建）已经轮询到终态
        // 才会来取结果；历史记录点进来的那次若还在跑，也同样不该展示产物。
        guard status == .succeeded else {
            return BuildResult(
                pipelineRunId: pipelineRunId,
                status: head.status,
                createdAt: head.createdAt
            )
        }

        // API 6b：按 Job 名 → jobId → 「执行命令」步骤 → stepIndex / buildId。
        let target = try await flowService.buildStepTarget(
            pipelineId: pipelineId,
            pipelineRunId: pipelineRunId,
            jobID: head.jobID
        )
        try Task.checkCancellation()

        // API 7：整段读取日志并解析产物。
        //
        // 状态已经是 SUCCESS 了，但日志可能还差最后一次刷盘 —— 因此按有限次数
        // 重试读取，而不是一次没解析到就宣告"没有产物"。
        let artifacts = try await resolveArtifacts(
            pipelineRunId: pipelineRunId,
            pipelineId: pipelineId,
            target: target
        )

        // ⚠️ 这里**不做** `artifacts.apkURL != nil` 的断言。
        // 重试完仍然没有标记时，状态停在成功是准确的：服务端原文确实是 `SUCCESS`，
        // 界面会提示"构建成功，但没有找到 APK/二维码地址"。
        // 把它判成失败会误导用户去重跑一次已经成功的构建。
        return BuildResult(
            pipelineRunId: pipelineRunId,
            status: head.status,
            createdAt: head.createdAt,
            artifacts: artifacts
        )
    }

    /// 读日志、解析产物；没解析到就按 `resultParsing` 的参数有限重试。
    ///
    /// 返回的产物**可能为空**（两个字段都是 `nil`），调用方不得据此构造失败态，
    /// 原因见 `BuildResult` 的注释。
    ///
    /// 「没有产物」的判定只看 APK 地址：二维码地址是同一段脚本的相邻标记，
    /// 若服务端将来只改了二维码那一段，报"没有找到 APK"仍然比静默展示半个结果准确。
    private func resolveArtifacts(
        pipelineRunId: Int,
        pipelineId: String,
        target: StepTarget
    ) async throws -> BuildArtifacts {
        var last = BuildArtifacts()

        for attempt in 1...resultParsing.maxAttempts {
            let logs = try await flowService.fetchStepLog(
                pipelineId: pipelineId,
                pipelineRunId: pipelineRunId,
                target: target
            )
            try Task.checkCancellation()

            last = parser.parse(logs)
            if last.apkURL != nil { return last }

            // 最后一次不必再等 —— 等完也不会再读一次日志了。
            if attempt < resultParsing.maxAttempts {
                try await Task.sleep(for: resultParsing.delay)
            }
        }

        return last
    }
}
