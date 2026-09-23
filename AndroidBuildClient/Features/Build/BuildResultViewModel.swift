import Foundation
import Observation

/// 「某一次运行的构建结果」页面的状态持有者。
///
/// 它只做三件事：拿 `BuildResult`、把加载过程表达成 loading / error、以及
/// 判定**此刻的界面上允许展示哪些产物**。
///
/// ⚠️ **它不知道 `jobId` / `stepIndex` / `buildId` / `offset` / `limit`。**
/// 从「运行详情」一路问到「日志里那两个标记」的整条链路全在
/// `BuildService.fetchBuildResult(pipelineRunId:pipelineId:)` 里面；
/// 这一层只把「哪条流水线上的哪一次运行」两个 ID 传进去、拿一个 `BuildResult` 出来。
/// 在这里重写一遍那条链路，等于给"换个接口找产物"制造第二个修改点。
///
/// ⚠️ **它也不知道 `BuildState`。** `BuildState` 描述的是「本客户端的打包流程
/// 走到哪一步」（触发中 / 轮询中 / 取结果中），表达不了 `CANCELED` 与认不出的
/// 状态；而结果页将来既服务"当前构建"也服务"从历史记录点进来"，后者根本
/// 不经过 `BuildState`。这一层只依赖 `BuildResult`。
@MainActor
@Observable
final class BuildResultViewModel {

    // MARK: - 状态

    /// 取回来的构建结果。还没加载完、或加载失败时为 `nil`。
    private(set) var result: BuildResult?

    /// 是否正在加载。**不能**用 `result == nil` 代替它 ——
    /// "还没去取"与"取回来了但结果为空"是两件事。
    private(set) var isLoading = false

    /// 加载失败的原因。加载中与加载成功时都是 `nil`。
    private(set) var errorMessage: String?

    /// 唯一的数据来源。不进 `AppModel`，也没有全局单例 ——
    /// 构造器注入，默认值就是生产实现（与 `BuildViewModel` 同一套写法）。
    @ObservationIgnored
    private let buildService: any BuildServiceProtocol

    init(buildService: any BuildServiceProtocol = BuildService()) {
        self.buildService = buildService
    }

    // MARK: - 派生属性

    /// 归类后的状态。还没取到结果时为 `nil`（"还没结果"与"认不出的状态"是两回事）。
    var runStatus: PipelineRunStatus? {
        result?.runStatus
    }

    /// **界面上允许展示的产物**：只有成功终态、且确实解析到了产物才非 `nil`。
    ///
    /// ⚠️ 这里必须自己判一次，不能只依赖 `BuildService` 已经保证"非成功状态
    /// 产物为空"。原因是那道保证失效时的后果特别严重 —— 认不出的状态值如果
    /// 被当成成功，界面上就会出现一个属于**另一次运行**的 APK 地址。
    /// 两道闸各自独立失效，任何一道单独都足以挡住。
    ///
    /// 这个判断放在 ViewModel 而不是 View 里，是为了让它**能被测试**：
    /// View 的 `if` 分支断言不到，而这条规则一旦破了就是"未知状态显示出一个
    /// 来路不明的 APK 地址"。
    var visibleArtifacts: BuildArtifacts? {
        guard
            let result,
            result.isSuccessful,
            !result.artifacts.isEmpty
        else {
            return nil
        }

        return result.artifacts
    }

    // MARK: - 加载

    /// 取某一次运行的构建结果。
    ///
    /// `pipelineId` 只是**这次调用**的参数（它标明这条运行属于哪条流水线），
    /// 不保存成可变状态：结果页在展示阶段完全用不到它，存下来只会多一份可能与
    /// `pipelineRunId` 对不上的字段。
    ///
    /// 重复调用是安全的：旧的错误会被清掉，新结果覆盖旧结果。
    func load(
        pipelineRunId: Int,
        pipelineId: String
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            result = try await buildService.fetchBuildResult(
                pipelineRunId: pipelineRunId,
                pipelineId: pipelineId
            )
        } catch is CancellationError {
            // 视图消失导致的任务取消不是错误，界面上不该出现任何提示。
            // 与 `BuildViewModel` 的处理保持一致。
        } catch {
            result = nil
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - 辅助

    /// 错误 → 展示文案。
    ///
    /// 各服务层的错误类型都实现了 `LocalizedError`，取它的 `errorDescription`；
    /// 其余错误退回 `String(describing:)`。文案来自错误类型本身，
    /// 不在这里拼接口地址、请求头或任何配置内容。
    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
