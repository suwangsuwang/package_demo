import Foundation

/// 流水线相关错误。
///
/// ⚠️ **这里刻意没有「流水线成功但没解析到产物」这一项。**
/// 那不是错误态：服务端返回的 `status` 原文就是 `SUCCESS`，
/// 只是日志里没有产物标记（典型原因是打包脚本改了输出格式）。
/// 把它做成一个 `case` 就会有人拿它去构造 `.failed`，界面于是显示"构建失败"，
/// 引导用户去重跑一次**已经成功**的流水线。
/// 这种情形由 `BuildState.success(空产物)` + 界面上的一句中性提示表达。
enum FlowServiceError: Error, Sendable, Equatable {
    /// 接口地址 / 组织 ID / 流水线 ID 等配置缺失。
    case configurationMissing(String)
    /// 流水线执行失败（服务端状态为 `FAIL`）。
    case pipelineFailed(String)
    /// 未能从响应中确定本次运行 / Job / Build 的 ID。
    case missingIdentifier(String)
    /// 还没选中任何代码分支就触发了打包。
    ///
    /// ⚠️ 这一项存在的唯一理由是**拦住"默认分支"这条退路**。
    /// 分支没选出来时若悄悄退回一个默认值（以前是写死的 `test`），
    /// 表现是用户选了 A 分支、实际构建了 B 分支的包，而界面上一路显示"构建成功"。
    /// 宁可明确失败，也不能构建一个用户没选过的分支。
    case missingBranchSelection
    /// 触发接口返回的 `pipelineRunId` 不是一个有效值（非正数）。
    case invalidPipelineRunID(Int)
    /// 轮询超时。
    case pollingTimedOut(Duration)
}

extension FlowServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .configurationMissing(let item):
            "缺少配置：\(item)。请检查 buildconfig.local.json。"
        case .pipelineFailed(let message):
            "流水线执行失败：\(message)"
        case .missingIdentifier(let detail):
            "无法从接口响应中确定 \(detail)。"
        case .missingBranchSelection:
            """
            还没有选中代码分支，无法触发打包。
            请等待分支列表加载完成并选择其中一个分支。
            """
        case .invalidPipelineRunID(let value):
            """
            触发接口返回的 pipelineRunId 不是有效值（收到 \(value)）。
            请到 Yunxiao 控制台确认本次运行是否真的被创建。
            """
        case .pollingTimedOut(let duration):
            "等待流水线完成超时（已等待 \(duration.description)）。"
        }
    }
}
