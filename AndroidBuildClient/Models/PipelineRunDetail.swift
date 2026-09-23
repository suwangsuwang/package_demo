import Foundation

/// 单次运行详情。
///
/// 接口：`GET …/runs/{pipelineRunId}`（注意是 `/runs`，不是 `/pipelineRuns`）
/// ```json
/// { "pipelineRunId": 30, "pipelineId": 5000001, "status": "RUNNING" }
/// ```
///
/// 除这三个已确认字段外，响应里还包含 `stages` 树 —— 那是 `jobId` 的唯一来源：
/// `stages → stageInfo → jobs → 找到 name == "编译并构建上传" → 取 id`。
/// 因此这里保留一份原始的 `stages` 结构，但**只建模到需要的那几层**。
struct PipelineRunDetail: Sendable, Equatable, Decodable {

    let pipelineRunId: Int
    let pipelineId: Int
    let status: String
    /// 运行开始时间（毫秒时间戳）。**可选** —— 这个端点的响应有时只给
    /// `createTime` / `updateTime`，缺 `startTime` 时是 `nil` 而不是解码失败。
    let startTime: Int64?
    /// 运行创建时间（毫秒时间戳）。**实测这个端点给的就是它，没有 `startTime`。**
    ///
    /// 与历史记录接口（`GET …/runs`）给 `startTime` 恰好相反，两者**没有共同的
    /// 起始时间字段** —— 同一个事实在一条链路上叫 `startTime`、在另一条上叫
    /// `createTime`。界面上的「构建时间」两条链路都要能显示，所以两个字段都建模，
    /// 由 `FlowService.fetchRunHead` 取先有的那个。
    ///
    /// 同样可选：接口没给就是 `nil`，**不用本地当前时间兜底** ——
    /// 编出来的时间看不出是编的（见 `BuildServiceTests.missingStartTimeStaysNil`）。
    let createTime: Int64?
    /// 运行中的阶段树。轮询时可能为空。
    let stages: [Stage]?

    var runStatus: PipelineRunStatus { PipelineRunStatus(rawStatus: status) }

    /// 在 `stages → stageInfo → jobs` 里按名字找 Job ID。
    ///
    /// 找不到返回 `nil`，由调用方报错 —— 不退回"取第一个 Job"之类的猜测。
    func jobID(named name: String) -> Int? {
        for stage in stages ?? [] {
            for job in stage.stageInfo?.jobs ?? [] where job.name == name {
                return job.id
            }
        }
        return nil
    }

    struct Stage: Sendable, Equatable, Decodable {
        let stageInfo: StageInfo?
    }

    struct StageInfo: Sendable, Equatable, Decodable {
        let jobs: [Job]?
    }

    struct Job: Sendable, Equatable, Decodable {
        /// 本次运行的 Job ID，**每次运行都不同**。
        let id: Int
        let name: String
    }
}
