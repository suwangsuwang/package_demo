import Foundation

/// 流水线单次运行的状态。
///
/// 接口实际出现过的取值：`RUNNING` / `SUCCESS` / `FAIL` / `CANCELED`
/// （`CANCELED` 是在历史记录里实测到的 —— 上一次运行还没结束就再次触发，
/// 前一次会被服务端取消）。
///
/// 除这些之外的值一律归入 `unknown`，并且**按"未结束"处理** ——
/// 认不出来就继续轮询，绝不凭猜测提前判成败。
enum PipelineRunStatus: Sendable, Equatable {
    /// 仍在排队或执行中。
    case running
    /// 执行成功。
    case succeeded
    /// 执行失败。
    case failed
    /// 被取消（通常是本次运行尚未结束就再次触发了流水线）。
    case canceled
    /// 状态字符串无法归类。**不等于失败**，轮询会继续。
    case unknown(String)

    /// 从接口返回的状态原文归类。
    init(rawStatus: String) {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "RUNNING": self = .running
        case "SUCCESS": self = .succeeded
        case "FAIL", "FAILED": self = .failed
        case "CANCELED", "CANCELLED": self = .canceled
        default: self = .unknown(rawStatus)
        }
    }

    /// 是否已经结束（轮询可以停止）。
    ///
    /// `unknown` 返回 `false`：宁可轮询到超时，也不要凭猜测提前判成败。
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled: true
        case .running, .unknown: false
        }
    }

    var displayText: String {
        switch self {
        case .running: "正在执行流水线"
        case .succeeded: "流水线执行成功"
        case .failed: "流水线执行失败"
        case .canceled: "流水线已取消"
        case .unknown(let raw): "流水线状态：\(raw)（未识别的状态值）"
        }
    }
}
