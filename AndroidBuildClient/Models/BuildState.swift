import Foundation

/// 一次打包任务的对外状态机。
///
/// `BuildViewModel` 只暴露这个枚举，UI 不关心流水线内部的 Job / Step 细节。
/// 刻意保持扁平 —— 不做复杂状态机。
enum BuildState: Sendable, Equatable {
    /// 尚未开始。
    case idle
    /// 正在触发流水线（POST /runs），此时还不知道本次 `pipelineRunId`。
    case triggering
    /// 已触发，正在轮询。
    ///
    /// - Parameters:
    ///   - pipelineRunId: **本次运行**的 ID，从触发接口返回。
    ///   - serverStatus: 服务端最近一次返回的状态**原文**（例如 `RUNNING`）。
    ///     刚触发、还没查到第一次时为 `nil`。
    ///     这里刻意保留原文而不是归类后的枚举：界面要如实展示服务端的用词，
    ///     而不是把 `RUNNING` 压成"运行中"再翻译回来。
    case running(pipelineRunId: Int, serverStatus: String?)
    /// 运行已成功，正在取 Job / Step / 日志并解析产物。
    case fetchingResult
    /// 流水线**执行成功**，结果区展示 `artifacts` 里解析到的产物。
    ///
    /// ⚠️ **这个状态存在"没有产物"的情形**，不是构造错误：
    /// 流水线返回 `SUCCESS`，但日志里找不到产物标记时，客户端会按有限次数重试，
    /// 重试完仍没有就停在这里，由界面提示"构建成功，但没有找到 APK/二维码地址"。
    /// 把它建模成失败是不准确的 —— 服务端的状态原文确实是 `SUCCESS`，
    /// 说成"构建失败"会误导用户去重跑一次。
    ///
    /// 因此不要按 `artifacts.apkURL != nil` 来构造失败态。
    case success(BuildArtifacts)
    /// 失败，`message` 直接展示给用户。
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .triggering, .running, .fetchingResult: true
        case .idle, .success, .failed: false
        }
    }

    /// 本次运行的 ID。只有轮询阶段才拿得到。
    var pipelineRunId: Int? {
        if case .running(let pipelineRunId, _) = self { return pipelineRunId }
        return nil
    }

    /// 服务端返回的状态原文，例如 `RUNNING`。没查到之前为 `nil`。
    var serverStatus: String? {
        if case .running(_, let serverStatus) = self { return serverStatus }
        return nil
    }

    /// UI 上的状态文案。
    var displayText: String {
        switch self {
        case .idle: "等待开始"
        case .triggering: "正在触发流水线…"
        case .running(let pipelineRunId, let serverStatus):
            // 有服务端原文就一并显示 —— 让"正在跑"这件事有据可依，不是客户端自说自话。
            if let serverStatus {
                "正在执行流水线（Run ID：\(pipelineRunId)，服务端状态：\(serverStatus)）"
            } else {
                "正在执行流水线（Run ID：\(pipelineRunId)）"
            }
        case .fetchingResult: "构建完成，正在获取打包结果…"
        case .success: "构建成功"
        case .failed: "构建失败"
        }
    }

    var artifacts: BuildArtifacts? {
        if case .success(let artifacts) = self { return artifacts }
        return nil
    }

    var message: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// 文案是否应当以错误色展示。
    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}
