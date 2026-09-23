import Foundation

/// Codeup（代码库 / 分支）相关错误。
///
/// ⚠️ **这里的所有文案都不允许出现 Token、请求头、响应体。**
/// 涉及地址的地方只写"流水线里配置的仓库地址"，因为仓库地址属于私有资源，
/// 完整打印出来会把组织内的仓库路径留在日志和截图里。
enum CodeupServiceError: Error, Sendable, Equatable {

    /// 流水线没有配置任何代码源（`sources` 缺失或为空）。
    case pipelineHasNoSource
    /// 流水线有代码源，但里面没有仓库地址（`data.repo` 为空）。
    ///
    /// 这两种情况分开是有意义的：前者是流水线还没配代码源，
    /// 后者是配了但地址字段是空的 —— 排查方向完全不同。
    case pipelineSourceHasNoRepository
    /// 组织下的仓库列表为空。
    case emptyRepositoryList
    /// 仓库列表里找不到与流水线对应的那一个。
    ///
    /// 附带上仓库数量：数量为 0 与"有 37 个但都对不上"是两种不同的问题
    /// （前者通常是 Token 权限只覆盖了部分组织，后者通常是流水线换了仓库）。
    case repositoryNotFound(repositoryCount: Int)
    /// 该仓库没有任何分支。
    case emptyBranchList(repositoryName: String?)
}

extension CodeupServiceError: LocalizedError {
    var errorDescription: String? {
        // 每个分支都写 `return`：`emptyBranchList` 需要先算一个局部量，
        // 一旦某个分支是多语句，整个 switch 就不能当表达式用。
        switch self {
        case .pipelineHasNoSource:
            return "流水线没有配置代码源，无法确定要获取哪个仓库的分支。请到 Yunxiao 控制台为流水线添加代码源。"
        case .pipelineSourceHasNoRepository:
            return "流水线的代码源里没有仓库地址，无法确定要获取哪个仓库的分支。请到 Yunxiao 控制台检查代码源配置。"
        case .emptyRepositoryList:
            return "该组织下没有查询到任何代码库，请检查 Token 权限与组织 ID 配置。"
        case .repositoryNotFound(let count):
            return """
            在代码库列表中找不到该流水线使用的仓库（已查询到 \(count) 个代码库）。
            请确认 Token 是否有该仓库的读取权限。
            """
        case .emptyBranchList(let repositoryName):
            let subject = repositoryName.map { "代码库「\($0)」" } ?? "该代码库"
            return "\(subject)下没有查询到任何分支，请确认仓库是否为空。"
        }
    }
}
