import Foundation

/// 把流水线里的「仓库地址」对应到 Codeup 仓库列表里的某个仓库。
///
/// 为什么需要这一步：流水线详情给的 `sources[].data.repo` 是一个**地址**，
/// 而 Codeup 取分支的接口要的是 `repositoryId`（一个数字）。
/// 两者之间没有可直接推导的关系，只能遍历仓库列表做对应。
///
/// ⚠️ **绝不做模糊的名字匹配。** 仓库名可能重复，
/// 用 `name.contains(...)` 之类的规则选出一个"看起来像"的仓库，
/// 失败时的表现是**安静地取到另一个仓库的分支列表** ——
/// 界面上一路正常，直到构建出来的包不对才发现。
/// 因此这里的规则只有两条，都是**结构化**的：
/// 1. 原文精确相等（`webUrl == pipelineRepo`）
/// 2. 归一化后相等（去掉 scheme / 结尾斜杠 / `.git` / 百分号编码的差异）
/// 两条都匹配不上就返回 `nil`，由调用方明确报错。
enum RepositoryMatcher {

    /// 在仓库列表里找出与 `pipelineRepo` 对应的那一个。
    ///
    /// - Returns: 匹配到的仓库；**匹配不到返回 `nil`**（不返回"最像的那个"）。
    static func match(
        pipelineRepo: String,
        repositories: [CodeupRepository]
    ) -> CodeupRepository? {
        let target = pipelineRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        // 第一优先级：原文精确相等。
        if let exact = repositories.first(where: {
            $0.webUrl?.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            return exact
        }

        // 第二优先级：归一化后相等。
        //
        // 归一化会把两侧都抹平，因此只有当**至少一侧**真的归一化过
        // （即原文不同、归一化后才相同）时才用它 —— 否则上面的精确匹配
        // 早就返回了，走到这里说明原文都不相等。
        let normalizedTarget = normalizeRepositoryURL(target)
        guard !normalizedTarget.isEmpty else { return nil }
        return repositories.first { repository in
            guard let webUrl = repository.webUrl else { return false }
            let normalized = normalizeRepositoryURL(webUrl)
            return !normalized.isEmpty && normalized == normalizedTarget
        }
    }

    /// 把仓库地址归一化成可比对的形式。
    ///
    /// 抹平的差异仅限于**同一个地址的不同写法**：
    /// - scheme（`https://` / `http://` 前缀）与 scp 形式（`git@host:path`）
    /// - 结尾的斜杠
    /// - 结尾的 `.git`
    /// - 主机名的大小写（域名不区分大小写；**路径的大小写是有意义的，不抹平**）
    /// - 百分号编码（`%2F` 与 `/`）
    ///
    /// ⚠️ **不删除路径中真正有意义的内容。** 例如
    /// `…/example-group/ExampleApp` 与 `…/example-group/ExampleApp2` 归一化后必须仍然不同，
    /// 所以这里不做任何前缀 / 包含关系的裁剪，只做上面那几项等价替换。
    static func normalizeRepositoryURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        // 百分号编码还原：`%2F` → `/`。
        // 先做这一步，后面的路径归一化才能作用在同一种形态上。
        value = value.removingPercentEncoding ?? value

        // scheme：`https://` / `http://` / `ssh://` 统一去掉。
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        } else if value.hasPrefix("git@") {
            // scp 形式 `git@host:path` → `host/path`。
            // 只去掉 `git@`，**主机名必须留着** —— 它和路径一样是地址的一部分，
            // 丢掉它会让 `git@host:path` 与 `https://host/path` 永远比不相等。
            let hostAndPath = value.dropFirst("git@".count)
            if let colon = hostAndPath.firstIndex(of: ":") {
                value = hostAndPath[..<colon] + "/" + hostAndPath[hostAndPath.index(after: colon)...]
            } else {
                value = String(hostAndPath)
            }
        }

        // 主机名与路径之间归一成恰好一个 `/`。
        // 上面两个分支之后一般已经是这样，这一步兜住
        // `https:///path`（多一个斜杠）这类畸形写法。路径本身原样保留。
        if !value.hasPrefix("/"), let slash = value.firstIndex(of: "/") {
            let host = value[..<slash]
            let rest = value[slash...].drop { $0 == "/" }
            value = host + "/" + rest
        }

        // 结尾斜杠与结尾 `.git`：可能同时存在（`repo.git/`），因此循环剥。
        while true {
            if value.hasSuffix("/") {
                value.removeLast()
            } else if value.lowercased().hasSuffix(".git") {
                value.removeLast(4)
            } else {
                break
            }
        }

        // 主机名大小写不敏感（域名本来就不区分大小写）。
        // 路径部分保持原样 —— 只有这里的大小写是**有意义的**，
        // 统一转小写会把 `example-group/Foo` 和 `example-group/foo` 当成同一个仓库。
        if let slash = value.firstIndex(of: "/") {
            let host = value[..<slash].lowercased()
            value = host + value[slash...]
        } else {
            value = value.lowercased()
        }

        return value
    }
}
