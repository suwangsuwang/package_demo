import Foundation

/// 一个 Codeup 代码库。
///
/// 接口：`GET /oapi/v1/codeup/organizations/{organizationId}/repositories`
/// ```json
/// [ { "id": 8000002, "name": "ExampleApp",
///     "webUrl": "https://codeup.aliyun.com/<org>/example-group/ExampleApp.git",
///     "pathWithNamespace": "example-group/ExampleApp", … } ]
/// ```
///
/// ⚠️ **这个类型存在的唯一理由是把「仓库地址」换成「仓库 ID」。**
/// 流水线详情里给的是 `sources[].data.repo`（一个地址），
/// 而 Codeup 取分支的接口要的是 `repositoryId`（一个数字）。
/// 两者之间没有可以直接推导的关系，只能靠这个列表做一次对应 —— 见 `RepositoryMatcher`。
///
/// 响应里其余几十个字段（创建时间、可见性、许可证…）一律不建模：
/// 不知道用途的值就不要读进来。
///
/// `Identifiable` 用 `id`（服务端给的数字），不是名字 ——
/// 仓库名可能重复，靠名字选中会指向另一个仓库。
struct CodeupRepository: Sendable, Equatable, Decodable, Identifiable {

    /// 仓库 ID。请求分支列表时拼进路径，**不允许写死**。
    let id: Int
    /// 仓库名。仅用于展示与排查，**不参与匹配**（见 `RepositoryMatcher`）。
    let name: String?
    /// 仓库的 Web 地址。与流水线 `sources[].data.repo` 比对的就是它。
    let webUrl: String?
    /// 带命名空间（组织内路径）的仓库路径，例如 `example-group/ExampleApp`。
    /// 仅用于展示与排查，**不参与匹配**。
    let pathWithNamespace: String?
}
