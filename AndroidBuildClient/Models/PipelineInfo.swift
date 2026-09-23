import Foundation

/// 流水线基本信息。
///
/// 接口：`GET /oapi/v1/flow/organizations/{organizationId}/pipelines/{pipelineId}`
/// ```json
/// { "name": "Example-App-Android", "id": 5000001, "pipelineConfigId": 3000001,
///   "pipelineConfig": { "version": 35, … } }
/// ```
///
/// ⚠️ **`version` 不在根节点上**，它在 `pipelineConfig.version` 里。
/// 这一点曾经写错过：模型按"根节点有 `version`"建模，于是每次进打包页
/// 都在标题下面挂一行 `PipelineInfo 缺少字段 version（在 响应根节点）` ——
/// 而这条错误和数据本身完全无关，看起来像 Token 或网络出了问题。
///
/// 除这几个字段外，响应里还有一大坨 `pipelineConfig`：那是流水线的完整配置
/// （触发规则、源、环境变量等）。客户端**不需要知道流水线内部怎么配的**
/// （也绝不去改它），因此**只从里面取两样东西**：`version`（展示用）
/// 与 `sources[].data.repo`（触发打包时 `runningBranchs` 的键）。
/// 其余一概不建模。
struct PipelineInfo: Sendable, Equatable, Decodable {

    let id: Int
    let name: String
    let pipelineConfigId: Int
    /// 流水线的完整配置。**整体可选** —— 取不到也只是少显示一个版本号，
    /// 不该让整个打包页因为一个展示字段而加载失败。
    let pipelineConfig: PipelineConfig?

    /// 流水线版本。字段缺失时为 `nil`，界面显示占位符。
    var version: Int? { pipelineConfig?.version }

    struct PipelineConfig: Sendable, Equatable, Decodable {
        /// 每次保存流水线都会变，仅用于展示。
        let version: Int?
        /// 流水线的代码源。触发打包时要用它的仓库地址作为 `runningBranchs` 的键。
        ///
        /// **整体可选** —— 取不到只是发不出带参数的触发请求，
        /// 不该让流水线详情接口整个失败。
        let sources: [PipelineSource]?
    }

    /// 代码源列表。没有 `sources` 字段时是空数组（不是 `nil`）——
    /// 「没有配置代码源」与「配置了但没有地址」由调用方分别判断，
    /// 因此这里不做取舍，原样交出去。
    var sources: [PipelineSource] { pipelineConfig?.sources ?? [] }

    /// 代码源里配置的仓库地址。
    ///
    /// 触发请求体的形状是
    /// `runningBranchs: { "<仓库地址>": "<分支>" }`，
    /// 也就是说仓库地址是**动态内容**，不是可以写死的常量。
    /// 实测该地址在整个仓库里**没有任何一处可以硬编码**——
    /// 它只存在于流水线配置里，只能从接口响应读出来。
    ///
    /// ⚠️ 响应里 `sources[].data` 还有二十来个字段
    /// （`serviceConnectionId` / `credentialId` / `commit` …），
    /// 客户端一律不建模：不知道用途的值就不要读进来。
    var repoURL: String? {
        sources
            .lazy
            .compactMap { $0.data?.repo?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// 代码源里保存的分支。
    ///
    /// 只作为**界面初始选中的候选**：它不保证仍然存在于仓库里
    /// （流水线配置是过去某一刻保存下来的快照），因此调用方必须先确认
    /// 它确实在分支列表里，才能拿它当默认选中项。
    var sourceBranch: String? {
        sources
            .lazy
            .compactMap { $0.data?.branch?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

/// 一个代码源。
///
/// 接口原文（已实测）：
/// ```json
/// { "type": "codeup", "sign": "example-sign", "name": "ExampleApp_57vT",
///   "label": "example-group/ExampleApp",
///   "data": { "branch": "test", "repo": "https://<host>/<org>/<repo>.git", … } }
/// ```
struct PipelineSource: Sendable, Equatable, Decodable {

    /// 代码源类型，例如 `codeup`。
    let type: String?
    /// 代码源数据。仓库地址在里面。
    let data: SourceData?

    struct SourceData: Sendable, Equatable, Decodable {
        /// 仓库地址。触发请求体里 `runningBranchs` 的**键**。
        let repo: String?
        /// 流水线配置里保存的默认分支。**不用于触发** ——
        /// 用哪个分支由用户在界面上选，这个字段只做参考/排查用。
        let branch: String?
    }
}
