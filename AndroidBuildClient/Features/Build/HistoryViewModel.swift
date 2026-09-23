import Foundation
import Observation

/// 历史打包记录的**展示层** ViewModel。
///
/// ⚠️ **它不取数。** 历史数据的唯一业务来源是 `BuildViewModel.history` ——
/// 由 `BuildViewModel` 走 `FlowService.fetchPipelineRuns(environment:)` 拉取，
/// 再原样传进来。这里不调用 `FlowService` / `BuildService` / `APIClient`，
/// 不发任何请求，也不读 `environment` 或流水线身份：
/// ```
/// BuildViewModel.history: [PipelineRun]
///     → HistoryView(runs:isLoading:)
///         → HistoryViewModel        ← 只做展示变换
///             → HistoryRow          ← 只做渲染
/// ```
/// 而不是 `HistoryView → HistoryViewModel → FlowService → Network`。
///
/// ⚠️ **它只有这么薄是刻意的。** Phase 5-C 是**纯结构提取**：把 `BuildView`
/// 里的历史展示搬出来，数据的**所有权**仍然留在 `BuildViewModel`。
/// 等 5-D / 5-E 真正引入导航与历史详情之后，再决定它是否需要承担更多职责。
/// 现在不要给它加取数、刷新、状态机、repository 这些东西。
///
/// ⚠️ **它由 `HistoryView` 在 body 里按当前入参重新构造，而不是 `@State` 持有的。**
/// 原因是历史列表会在一次打包结束后被 `BuildViewModel.refreshHistory()` 更新：
/// `@State` 只在**视图身份变化**时才重建，父视图带着新的 `runs` 重绘时它会保留
/// 旧值 —— 界面会一直停在上一次刷新出来的那份列表上（"打包完成了，记录里却
/// 看不到刚跑完的那一次"）。历史数据本来就存在 `BuildViewModel` 里，这里只做
/// 变换，所以每次从入参重新构造反而是正确的做法。
@MainActor
@Observable
final class HistoryViewModel {

    /// 完整历史记录。**原样来自 `BuildViewModel.history`** ——
    /// 不排序、不筛选、不改数量上限。要截断只在 `displayedRuns` 里做。
    private(set) var runs: [PipelineRun]

    /// 历史记录是否正在加载。同样来自 `BuildViewModel`，只用于决定空态文案
    /// （「正在加载…」还是「暂无记录」）与标题旁那颗菊花。
    private(set) var isLoading: Bool

    init(runs: [PipelineRun], isLoading: Bool) {
        self.runs = runs
        self.isLoading = isLoading
    }

    /// 界面上真正渲染的那一段：最近 10 条。
    ///
    /// 与 `BuildView` 原来那句 `viewModel.history.prefix(10)` 是同一件事，
    /// 位置从 View 挪到了这里。不做分页、不做"加载更多"。
    var displayedRuns: ArraySlice<PipelineRun> {
        runs.prefix(10)
    }
}
