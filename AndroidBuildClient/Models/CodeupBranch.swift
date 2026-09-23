import Foundation

/// 一个 Codeup 分支。
///
/// 接口：`GET /oapi/v1/codeup/organizations/{organizationId}/repositories/{repositoryId}/branches`
/// ```json
/// [ { "name": "test", "defaultBranch": false, "protected": false, … } ]
/// ```
///
/// `name` 就是 git 分支名原文，界面直接显示它，不做任何修饰 ——
/// 它就是触发请求体里 `runningBranchs` 实际发出去的值，
/// 写成"Test 分支"之类的话，界面上的字和线上分支名就对不上了。
///
/// `Identifiable` 用 `name`：同一个仓库里分支名不会重复，
/// 而响应里没有别的稳定标识可用。
struct CodeupBranch: Sendable, Equatable, Decodable, Identifiable, Hashable {

    /// git 分支名原文。**不允许写死任何取值**，全部来自接口。
    let name: String
    /// 是否是仓库的默认分支。
    ///
    /// ⚠️ **不要假设默认分支叫 `test` 或 `master`**，只能按这个标记判断。
    let defaultBranch: Bool
    /// 是否是保护分支。仅用于展示，不参与任何流程判断。
    let protected: Bool

    var id: String { name }
}
