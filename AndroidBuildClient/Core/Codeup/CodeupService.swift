import Foundation

/// Codeup 能力抽象。
///
/// 只做两件事：拿仓库列表、拿某个仓库的分支列表。
/// **分页是这一层内部的事** —— `ViewModel` 不应该知道 `page` / `perPage` /
/// `x-next-page` 的存在，它只调用一次，拿到的是完整列表。
protocol CodeupServiceProtocol: Sendable {

    /// 当前组织下的**全部**代码库。
    func getRepositories() async throws -> [CodeupRepository]

    /// 某个代码库的**全部**分支。
    func getBranches(repositoryId: Int) async throws -> [CodeupBranch]
}

/// 真实实现：拼路径、翻页、做字段映射。HTTP 细节全部交给 `APIClient`。
struct CodeupService: CodeupServiceProtocol {

    private let api: any APIClientProtocol
    /// 配置来源。默认从磁盘读；测试注入固定值，避免测试依赖运行环境的配置文件。
    private let configProvider: @Sendable () throws -> BuildConfig

    init(
        api: any APIClientProtocol = APIClient(),
        config: @escaping @Sendable () throws -> BuildConfig = { try BuildConfig.load() }
    ) {
        self.api = api
        self.configProvider = config
    }

    // MARK: - 仓库列表

    func getRepositories() async throws -> [CodeupRepository] {
        let config = try configProvider()
        let path = AppConfiguration.Path.codeupRepositories(organizationId: config.organizationId)
        return try await fetchAllPages(path: path, decoding: CodeupRepository.self)
    }

    // MARK: - 分支列表

    func getBranches(repositoryId: Int) async throws -> [CodeupBranch] {
        let config = try configProvider()
        let path = AppConfiguration.Path.codeupBranches(
            organizationId: config.organizationId,
            repositoryId: String(repositoryId)
        )
        let branches = try await fetchAllPages(path: path, decoding: CodeupBranch.self)

        // 空分支列表在调用方那里是"无法选择分支"，不是"没有这个字段"，
        // 因此在这里就明确成错误，而不是让界面显示一个空的 Picker。
        guard !branches.isEmpty else {
            throw CodeupServiceError.emptyBranchList(repositoryName: nil)
        }
        return branches
    }

    // MARK: - 翻页

    /// 逐页取回某个列表接口的**全部**条目。
    ///
    /// 为什么要翻页而不是只取第一页：一个页面不保证覆盖全部数据。
    /// 少翻一页的表现是"找不到对应的仓库"或"分支列表里少几个分支" ——
    /// 前者看起来像配置错了，后者更糟：用户只是**看不到**某个分支，
    /// 不会得到任何提示，只会以为那个分支不存在。
    ///
    /// 页码推进的优先顺序（都来自**响应头**，不是猜的）：
    /// 1. `x-next-page` —— 服务端直接给下一页页码，最可靠
    /// 2. `x-total-pages` —— 拿当前页码与总页数比
    /// 3. `x-total` —— 拿已取条数与总条数比
    /// 4. 都没有时退化为"这一页取满了 `perPage` 条就继续"
    ///
    /// 第 4 条是**兜底**，不是主路径：它有可能多打一次空请求（拿回空数组即停），
    /// 但不会漏数据。`maxPages` 是它的上限 —— 没有上限的话，
    /// 服务端若总是返回满页，这个循环就停不下来了。
    private func fetchAllPages<T: Decodable & Sendable>(
        path: String,
        decoding type: T.Type
    ) async throws -> [T] {
        var collected: [T] = []
        var page = AppConfiguration.CodeupPaging.firstPage

        while page <= AppConfiguration.CodeupPaging.maxPages {
            let request = try URLRequest.yunxiao(
                path: path,
                method: "GET",
                query: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "perPage", value: String(AppConfiguration.CodeupPaging.perPage)),
                ]
            )

            let (items, response) = try await api.sendWithResponse(request, decoding: [T].self)
            collected.append(contentsOf: items)
            try Task.checkCancellation()

            guard let next = Self.nextPage(
                current: page,
                pageItemCount: items.count,
                totalSoFar: collected.count,
                response: response
            ) else {
                return collected
            }
            page = next
        }

        return collected
    }

    /// 下一页的页码；已经到最后一页时返回 `nil`。
    ///
    /// - Parameters:
    ///   - current: 当前页码。
    ///   - pageItemCount: **本页**取回的条数。
    ///   - totalSoFar: 到本页为止**累计**取回的条数。
    ///
    /// 两个计数都要传：`x-total` 比的是**累计**条数，
    /// 而"这一页取满了没有"的兜底比的是**本页**条数。
    /// 拿本页条数去和 `x-total` 比会**永远翻不到头** ——
    /// 比如总共 3 条、每页 2 条：第 2 页只有 1 条，`1 < 3` 成立，
    /// 于是继续翻第 3 页、第 4 页……直到撞上 `maxPages`，
    /// 每翻一页都把最后一页的数据重复收集一遍。
    private static func nextPage(
        current: Int,
        pageItemCount: Int,
        totalSoFar: Int,
        response: HTTPURLResponse
    ) -> Int? {
        let paging = AppConfiguration.CodeupPaging.self

        // 1. 服务端直接告诉下一页是哪一页。
        //    这一条要放在最前面：它比"自己算"更准，也是唯一能表达
        //    "后面还有，但页码不是 +1"的形式。
        if let raw = response.value(forHTTPHeaderField: paging.nextPageHeader) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空串 / `0` / 非数字都表示"没有下一页"，不是"页号解析失败"。
            guard let next = Int(trimmed), next > current else { return nil }
            return next
        }

        // 2. 总页数。
        if let raw = response.value(forHTTPHeaderField: paging.totalPagesHeader),
           let total = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return current < total ? current + 1 : nil
        }

        // 3. 总条数 —— 比的是**累计**条数。
        if let raw = response.value(forHTTPHeaderField: paging.totalHeader),
           let total = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return totalSoFar < total ? current + 1 : nil
        }

        // 4. 兜底：没有任何分页响应头时，按"这一页取满了没有"判断 —— 这里比的是**本页**条数。
        return pageItemCount >= paging.perPage ? current + 1 : nil
    }
}
