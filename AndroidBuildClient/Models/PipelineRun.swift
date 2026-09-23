import Foundation

/// 一次流水线运行记录。
///
/// 这个模型同时服务**两套字段不同的接口**，因此只保留它们的交集：
///
/// 1. 历史记录
///    `GET …/pipelines/{pipelineId}/runs` —— 返回**裸数组**：
///    ```json
///    [{ "status": "SUCCESS", "startTime": 1790046747000, "triggerMode": 4,
///       "pipelineRunId": 30, "pipelineId": 5000001, "endTime": 1790047099000,
///       "creator": null, "creatorAccountId": "…" }]
///    ```
/// 2. 单次运行详情
///    `GET …/pipelines/{pipelineId}/runs/{pipelineRunId}` —— 返回单个对象：
///    ```json
///    { "pipelineRunId": 30, "pipelineId": 5000001, "status": "RUNNING",
///      "triggerMode": 4, "createTime": 1790046747000, "updateTime": 1790046749000,
///      "stages": [ … ] }
///    ```
///
/// ⚠️ 两者**没有共同的起始时间字段**：历史记录给 `startTime`，运行详情给
/// `createTime` / `updateTime`，且详情里**根本没有** `startTime`。
/// 所以 `startTime` 只能是可选的 —— 否则轮询（走的是详情接口）会在解码这一步就失败，
/// 表现成"打包刚触发就报解析失败"，而真正的原因和 Token、配置、路径都无关。
///
/// `pipelineRunId` 是**每次运行都不同**的值，只能从响应里读，
/// 本项目任何地方都不允许把它写成常量。
struct PipelineRun: Sendable, Equatable, Decodable, Identifiable {

    let pipelineRunId: Int
    let pipelineId: Int
    /// 运行状态原文，例如 `RUNNING` / `SUCCESS` / `FAIL` / `CANCELED`。
    /// 保持字符串形态，语义归类交给 `PipelineRunStatus`。
    let status: String
    /// 毫秒时间戳。**只有历史记录接口会返回**；运行详情里没有这个字段，为 `nil`。
    let startTime: Int64?
    /// 毫秒时间戳。运行未结束时为 `null`；运行详情里同样没有这个字段。
    let endTime: Int64?
    let triggerMode: Int
    /// 触发者的账号 ID。两种触发方式下都可能是 `null`。
    ///
    /// 注意它是**账号 ID**（形如 `example-account-1`），不是姓名 ——
    /// 接口不会给姓名，客户端也没有"账号 ID → 姓名"的查询接口，
    /// 所以界面上直接展示 ID 原文，不做臆测。
    let creatorID: String?

    /// 接口给的是 `creatorAccountId`，但那个名字容易被读成"创建者的账号对象"；
    /// 它实际就是一个字符串 ID（也可能是 `null`）。映射在此显式写出，
    /// 免得改名时解码静默失败。
    private enum CodingKeys: String, CodingKey {
        case pipelineRunId
        case pipelineId
        case status
        case startTime
        case endTime
        case triggerMode
        case creatorID = "creatorAccountId"
    }

    var id: Int { pipelineRunId }

    /// 归类后的状态。
    var runStatus: PipelineRunStatus { PipelineRunStatus(rawStatus: status) }

    /// 归类后的触发方式。
    var trigger: TriggerMode { TriggerMode(rawValue: triggerMode) }
}

// MARK: - 触发方式

/// 运行详情里 `triggerMode` 的取值。
///
/// ⚠️ **客户端主动触发的接口不带任何 body**，无法指定触发方式，
/// 因此把界面上的「开始打包」说成"手动触发"是不准确的 ——
/// 实测经过本项目触发的运行，`triggerMode` 是 `4`（`POP_API`，
/// 见日志里的 `FLOW_SYSTEM_IDENTIFICATION_PARAM_TRIGGER_SOURCE`）。
///
/// 已确认的取值：
/// - `1`：在 Yunxiao 界面上手动点「运行」
/// - `4`：通过 API 触发 —— 也就是本客户端触发出来的方式
enum TriggerMode: Sendable, Equatable {

    case manual
    case api
    /// 其它取值。保留原文，不猜测含义。
    case other(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .manual
        case 4: self = .api
        default: self = .other(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .manual: "手动触发"
        case .api: "API 触发"
        case .other(let raw): "触发方式 \(raw)"
        }
    }
}
