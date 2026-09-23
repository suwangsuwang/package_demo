import Foundation

/// 「要看那一次运行」这件事的身份。
///
/// 它是 `NavigationLink(value:)` / `navigationDestination(for:)` 的导航值 ——
/// 表达的是**打开哪一次运行**，而不是「这次运行现在是什么状态」。
///
/// ⚠️ **为什么不用 `PipelineRun` 本身当导航值。**
/// `PipelineRun` 是一次运行的**快照**：它带着 `status` / `startTime` / `endTime`
/// 这些会随时间变化的字段。拿它当导航身份有两个后果，且都不会报错：
///
/// 1. 同一个 Run 在列表刷新前后是两个不相等的值（`RUNNING` → `SUCCESS`、
///    `endTime` 从 `nil` 变成有值），导航栈里的那个元素会跟着"变成另一个页面"；
/// 2. 历史接口给 `startTime`、运行详情接口**不给** —— 同一个 Run 从两个来源
///    构造出来也不相等。
///
/// 这个类型只留下身份，因此"同一次运行"永远等于它自己。它同时也满足
/// `navigationDestination(for:)` 对 `Hashable` 的要求，**不需要**给
/// `PipelineRun` 补协议（那会把上面那些快照字段一起卷进身份）。
///
/// ⚠️ **与 `CurrentBuildRun` 的关系**：两者的字段完全一致，是同一个概念在
/// 两条路径上的两个名字（`CurrentBuildRun` 服务当前构建，本类型服务导航）。
/// 刻意各留一份而不是合并：那个类型是 `BuildViewModel` 的内部快照，
/// 让它跨到导航层会把两条本来独立的状态线缠在一起。
struct BuildRunIdentity: Hashable, Sendable {

    /// 这一次运行的 ID。
    let pipelineRunId: Int

    /// 这条运行所属的**流水线 ID**。
    ///
    /// 类型是 `String`，而 `PipelineRun.pipelineId` 是 `Int` —— 这个不一致是
    /// 既有的：下游整条链路（`BuildResultView` → `BuildResultViewModel` →
    /// `BuildService` → `FlowService`）都收 `String`。所以从 `PipelineRun`
    /// 构造时**必须显式转换** `String(run.pipelineId)`，不要顺手去改
    /// `PipelineRun` 的类型。
    let pipelineId: String
}

extension BuildRunIdentity {

    /// 从一条历史记录取出它**属于哪一次运行**。
    ///
    /// 只读取两个身份字段，`status` / 时间 / 触发者一概不参与 ——
    /// 这正是它与「整条 `PipelineRun`」的区别。
    init(run: PipelineRun) {
        self.init(
            pipelineRunId: run.pipelineRunId,
            pipelineId: String(run.pipelineId)
        )
    }
}
