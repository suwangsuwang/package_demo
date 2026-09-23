import Foundation

/// Yunxiao / Flow 步骤日志。
///
/// 接口：`GET …/jobs/{jobId}/step/log?stepIndex=…&offset=0&limit=10000&buildId=…`
/// ```json
/// { "last": -1, "logs": "…完整日志…", "more": false }
/// ```
///
/// `last == -1` 不能理解成"没有日志" —— 已确认这是服务端的游标值，
/// 真正要解析的内容全在 `logs` 里。
struct StepLog: Sendable, Equatable, Decodable {
    /// 服务端返回的游标。整段读取下通常为 -1，不参与业务判断。
    let last: Int
    /// 日志正文。
    let logs: String
    /// 是否还有更多日志。
    let more: Bool
}
