import Foundation

/// 一次运行的构建结果 —— 界面上「构建详情」要展示的全部内容。
///
/// 这是 `BuildService.fetchBuildResult(pipelineRunId:pipelineId:)` 的返回值，
/// 当前构建跑完与从历史记录点进某一次运行，走的都是这一个类型。
///
/// ⚠️ **这里只放服务器确实给得出的字段。**
/// 运行详情（`/runs/{id}`）与历史记录（`/runs`）两个接口都**不返回**
/// branch / environment，客户端也不从别处（本地配置、本地历史库）补一个上去 ——
/// 那样展示出来的"分支 / 环境"只是客户端自己的猜测，与真实构建无关。
/// 服务器知道什么，就展示什么；将来接口真的提供了，再扩展这个模型。
struct BuildResult: Sendable, Equatable, Identifiable {

    /// 本次运行的 ID。**直接作为唯一标识**，不另外生成 UUID ——
    /// 它在 Yunxiao 侧本来就是唯一且稳定的。
    let pipelineRunId: Int

    /// 服务端返回的状态**原文**（`SUCCESS` / `FAIL` / `CANCELED`…）。
    ///
    /// 保留原文而不是只留归类后的枚举：界面要能展示服务端究竟回了什么，
    /// 归类成中文措辞之后用户就没法核对了。归类的结果见 `runStatus`。
    let status: String

    /// 运行开始时间（毫秒时间戳）。接口没给就是 `nil`，不用本地当前时间兜底。
    let createdAt: Int64?

    /// 产物地址。
    ///
    /// ⚠️ **只有成功终态才可能有值。** 非成功状态一律是空的
    /// （由 `BuildService` 保证，见那里的注释）——
    /// 「未知状态」绝不能被当成成功、更不能展示出一个来路不明的 APK 地址。
    let artifacts: BuildArtifacts

    init(
        pipelineRunId: Int,
        status: String,
        createdAt: Int64? = nil,
        artifacts: BuildArtifacts = BuildArtifacts()
    ) {
        self.pipelineRunId = pipelineRunId
        self.status = status
        self.createdAt = createdAt
        self.artifacts = artifacts
    }

    /// `pipelineRunId` 已经足够唯一，不重复生成 UUID。
    var id: Int { pipelineRunId }

    /// 归类后的状态。**至少五种**：运行中 / 成功 / 失败 / 已取消 / 未知。
    ///
    /// 不做「非成功即失败」的二值简化 —— 那会把 `CANCELED` 说成失败、
    /// 把认不出的状态值也压进失败里，而后者最危险：认不出 ≠ 失败，
    /// 更 ≠ 成功。这里只做归类，展示与判成败都交给调用方按枚举分支处理。
    var runStatus: PipelineRunStatus { PipelineRunStatus(rawStatus: status) }

    /// 是否成功终态。**只有它为真时界面才展示 APK / 二维码。**
    var isSuccessful: Bool { runStatus == .succeeded }
}
