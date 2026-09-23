import SwiftUI

/// 历史打包记录区块。
///
/// **纯展示。** 数据由 `BuildView` 传进来（`BuildViewModel.history` 是唯一数据源），
/// 本视图不取数、不刷新、不碰 `FlowService`。
///
/// ⚠️ **记录行现在仍然不可点击。** 没有 `NavigationLink` / `Button` /
/// `.onTapGesture`，也不持有任何"选中了哪一条"的状态 —— 从历史点进详情
/// 属于后面的阶段，不在本阶段的范围里。
struct HistoryView: View {

    /// 历史记录原文，来自 `BuildViewModel.history`。**这里不改它的内容与顺序。**
    let runs: [PipelineRun]

    /// 是否正在加载。只影响空态文案与标题旁那颗菊花。
    let isLoading: Bool

    var body: some View {
        // 展示层 ViewModel 按当前入参重新构造，见 `HistoryViewModel` 的注释：
        // 它绝不能是 `@State`，否则历史刷新后界面不会跟着更新。
        let viewModel = HistoryViewModel(runs: runs, isLoading: isLoading)

        return VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(spacing: 8) {
                Text("最近打包记录").font(.headline)
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if viewModel.runs.isEmpty {
                Text(viewModel.isLoading ? "正在加载…" : "暂无记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 只展示最近 10 条，不做分页。
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.displayedRuns) { run in
                        HistoryRow(run: run)
                    }
                }
            }
        }
    }
}

// MARK: - 单条记录

/// 历史记录里的一行。
///
/// 展示的字段全部来自历史记录接口的原文：`pipelineRunId` / `status` /
/// `triggerMode` / `startTime` / `endTime` / `creatorAccountId`。
/// 只有「耗时」是本地算出来的（`endTime - startTime`），其余不做任何加工 ——
/// 尤其是 `status`，直接显示服务端原文，而不是翻译成中文后再让用户去猜。
///
/// ⚠️ 保持 `private`：它只服务于 `HistoryView`。等历史行自身长出明显复杂逻辑
/// （比如可点击、带展开区）再考虑独立成文件。
private struct HistoryRow: View {

    let run: PipelineRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("#\(run.pipelineRunId)")
                .font(.callout.monospaced())
                .frame(width: 60, alignment: .leading)

            // 服务端状态原文，不是归类后的中文。
            Text(run.status)
                .font(.callout.monospaced())
                .foregroundStyle(Self.color(for: run.runStatus))
                .frame(width: 90, alignment: .leading)

            Text(run.trigger.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(Self.dateText(run.startTime))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(run.creatorID ?? "—")
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(run.creatorID ?? "该记录没有触发者账号 ID")

            Spacer(minLength: 12)

            if let startTime = run.startTime, let endTime = run.endTime {
                Text(Self.durationText(from: startTime, to: endTime))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if run.runStatus == .running {
                Text("进行中")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 辅助

    private static func color(for status: PipelineRunStatus) -> Color {
        switch status {
        case .succeeded: .green
        case .failed: .red
        case .canceled, .running, .unknown: .secondary
        }
    }

    /// 毫秒时间戳 → 本地时间文本。时间戳缺失时（运行详情接口不返回起始时间）显示占位符。
    private static func dateText(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "—" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return date.formatted(date: .numeric, time: .shortened)
    }

    private static func durationText(from start: Int64, to end: Int64) -> String {
        let seconds = max(0, end - start) / 1000
        return "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}
