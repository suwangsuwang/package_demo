import Foundation
import Testing

@testable import AndroidBuildClient

/// Codeup 仓库 / 分支接口的测试。
///
/// 两类断言：
/// 1. **路径与查询参数** —— 拼错了不会编译失败，只会 404 或返回空列表
/// 2. **翻页** —— 少翻一页的表现是"找不到对应的仓库"或"分支列表里少几个分支"，
///    后者尤其危险：用户只是看不到某个分支，不会得到任何提示
@Suite("Codeup 接口")
struct CodeupServiceTests {

    private static let org = "example-org-id"
    private static let repositoriesPath = "/oapi/v1/codeup/organizations/\(org)/repositories"
    private static let branchesPath = "/oapi/v1/codeup/organizations/\(org)/repositories/8000002/branches"

    private static func branchesPath(repositoryId: Int) -> String {
        "/oapi/v1/codeup/organizations/\(org)/repositories/\(repositoryId)/branches"
    }

    private static let config = BuildConfig(
        yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
        organizationId: org,
        pipelines: ["test": "5000001"]
    )

    private static func makeService(api: StubAPIClient) -> CodeupService {
        let config = Self.config
        return CodeupService(api: api, config: { config })
    }

    private static func repositoryPayload(ids: [Int]) -> String {
        let items = ids.map {
            #"{"id":\#($0),"name":"Repo\#($0)","webUrl":"https://codeup.aliyun.com/\#(org)/example-group/Repo\#($0).git","pathWithNamespace":"example-group/Repo\#($0)"}"#
        }
        return "[\(items.joined(separator: ","))]"
    }

    private static func branchPayload(names: [String]) -> String {
        let items = names.map {
            #"{"name":"\#($0)","defaultBranch":false,"protected":false}"#
        }
        return "[\(items.joined(separator: ","))]"
    }

    // MARK: - 路径与查询参数

    @Test("仓库列表走 /oapi/v1/codeup/...，不是 /oapi/v1/flow/...")
    func repositoriesUseCodeupPrefix() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .success(Self.repositoryPayload(ids: [1])))

        _ = try await Self.makeService(api: api).getRepositories()

        #expect(api.requestedPaths == [Self.repositoriesPath])
        #expect(api.requestedPaths.allSatisfy { $0.contains("/oapi/v1/codeup/") })
    }

    @Test("分支列表把 repositoryId 拼进路径，不写死")
    func branchesPathCarriesRepositoryID() async throws {
        let api = StubAPIClient()
        api.stubEverything(.success(Self.branchPayload(names: ["test"])))

        _ = try await Self.makeService(api: api).getBranches(repositoryId: 8000002)
        #expect(api.requestedPaths.first == Self.branchesPath)

        _ = try await Self.makeService(api: api).getBranches(repositoryId: 999)
        #expect(
            api.requestedPaths.last
                == "/oapi/v1/codeup/organizations/\(Self.org)/repositories/999/branches"
        )
    }

    @Test("第一页请求带 page=1&perPage=100")
    func firstPageQuery() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .success(Self.repositoryPayload(ids: [1])))

        _ = try await Self.makeService(api: api).getRepositories()

        let query = api.requestedQuery(forPath: Self.repositoriesPath)
        #expect(query["page"] == "1")
        #expect(query["perPage"] == "100")
    }

    // MARK: - 翻页：响应头驱动

    @Test("按 x-next-page 一直翻到没有下一页为止")
    func followsNextPageHeader() async throws {
        let api = StubAPIClient()
        api.stubSequence(path: Self.repositoriesPath, [
            .successWithHeaders(
                Self.repositoryPayload(ids: [1, 2]),
                headers: ["x-next-page": "2", "x-total": "5"]
            ),
            .successWithHeaders(
                Self.repositoryPayload(ids: [3, 4]),
                headers: ["x-next-page": "3", "x-total": "5"]
            ),
            .successWithHeaders(
                Self.repositoryPayload(ids: [5]),
                headers: ["x-total": "5"]
            ),
        ])

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.map(\.id) == [1, 2, 3, 4, 5], "必须把三页都取回来")
        let pages = api.requestedQueryValues(forPath: Self.repositoriesPath, name: "page")
        #expect(pages == ["1", "2", "3"], "页码应该依次是 1 / 2 / 3")
    }

    @Test("没有 x-next-page 时用 x-total-pages 判断是否继续")
    func fallsBackToTotalPagesHeader() async throws {
        let api = StubAPIClient()
        api.stubSequence(path: Self.repositoriesPath, [
            .successWithHeaders(
                Self.repositoryPayload(ids: [1, 2]),
                headers: ["x-total-pages": "2"]
            ),
            .successWithHeaders(
                Self.repositoryPayload(ids: [3]),
                headers: ["x-total-pages": "2"]
            ),
        ])

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.map(\.id) == [1, 2, 3])
        #expect(api.requestedQueryValues(forPath: Self.repositoriesPath, name: "page") == ["1", "2"])
    }

    @Test("既没有 x-next-page 也没有 x-total-pages 时用 x-total 判断")
    func fallsBackToTotalHeader() async throws {
        let api = StubAPIClient()
        api.stubSequence(path: Self.repositoriesPath, [
            .successWithHeaders(Self.repositoryPayload(ids: [1, 2]), headers: ["x-total": "3"]),
            .successWithHeaders(Self.repositoryPayload(ids: [3]), headers: ["x-total": "3"]),
        ])

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.map(\.id) == [1, 2, 3])
        #expect(api.requestedQueryValues(forPath: Self.repositoriesPath, name: "page") == ["1", "2"])
    }

    @Test("响应头一个都没有时，取满一页继续、取不满就停")
    func fallsBackToPageSizeWhenNoPagingHeaders() async throws {
        let api = StubAPIClient()
        // 第一页正好 100 条（满页）→ 继续；第二页 3 条（不满）→ 停。
        api.stubSequence(path: Self.repositoriesPath, [
            .success(Self.repositoryPayload(ids: Array(1...100))),
            .success(Self.repositoryPayload(ids: [101, 102, 103])),
        ])

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.count == 103)
        #expect(api.requestedQueryValues(forPath: Self.repositoriesPath, name: "page") == ["1", "2"])
    }

    @Test("x-next-page 为 0 表示没有下一页，不会去请求第 0 页")
    func zeroNextPageMeansStop() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .successWithHeaders(
            Self.repositoryPayload(ids: [1]),
            headers: ["x-next-page": "0"]
        ))

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.map(\.id) == [1])
        #expect(api.requestedPaths.count == 1, "不该再发第二次请求")
    }

    @Test("x-next-page 不是数字时不当作下一页，直接停下")
    func unparsableNextPageStops() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .successWithHeaders(
            Self.repositoryPayload(ids: [1]),
            headers: ["x-next-page": "abc"]
        ))

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.map(\.id) == [1])
        #expect(api.requestedPaths.count == 1)
    }

    @Test("x-total 小于本页条数时不会继续翻页")
    func totalSmallerThanPageStops() async throws {
        // 服务端给的 total 与条数不一致时，宁可停 —— 继续翻会一直翻到 maxPages。
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .successWithHeaders(
            Self.repositoryPayload(ids: [1, 2, 3]),
            headers: ["x-total": "1"]
        ))

        let repositories = try await Self.makeService(api: api).getRepositories()

        #expect(repositories.map(\.id) == [1, 2, 3])
        #expect(api.requestedPaths.count == 1)
    }

    // MARK: - 分支

    @Test("分支列表同样翻页")
    func branchesArePaginatedToo() async throws {
        let api = StubAPIClient()
        api.stubSequence(path: Self.branchesPath, [
            .successWithHeaders(Self.branchPayload(names: ["test"]), headers: ["x-total-pages": "2"]),
            .successWithHeaders(Self.branchPayload(names: ["release"]), headers: ["x-total-pages": "2"]),
        ])

        let branches = try await Self.makeService(api: api).getBranches(repositoryId: 8000002)

        #expect(branches.map(\.name) == ["test", "release"])
        #expect(api.requestedQueryValues(forPath: Self.branchesPath, name: "page") == ["1", "2"])
    }

    @Test("分支为空时明确报错，而不是返回一个空列表")
    func emptyBranchListIsAnError() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.branchesPath, .success("[]"))

        await #expect(throws: CodeupServiceError.emptyBranchList(repositoryName: nil)) {
            _ = try await Self.makeService(api: api).getBranches(repositoryId: 8000002)
        }
    }

    // MARK: - 真实报文形态

    @Test("真实分支报文能解码：多出来的 commit 字段被忽略，defaultBranch / protected 原样读出")
    func realBranchPayloadDecodes() async throws {
        // 照抄真实响应的一条：分支对象上还挂着完整的 `commit`（含 parentIds、
        // author/committer 两套信息）。客户端只用 name / defaultBranch / protected，
        // 多出来的字段必须被安静忽略 —— 否则接口一加字段，分支列表就整个解不出来。
        let api = StubAPIClient()
        api.stub(path: Self.branchesPath(repositoryId: 8000001), .success(
            """
            [
              {
                "commit": {
                  "authorEmail": "developer@example.com",
                  "authorName": "example-dev",
                  "authoredDate": "2025-06-05T23:15:05+08:00",
                  "committedDate": "2025-06-05T23:15:05+08:00",
                  "committerEmail": "developer@example.com",
                  "committerName": "example-dev",
                  "id": "1111111111111111111111111111111111111111",
                  "message": "feat: 添加示例功能",
                  "parentIds": ["2222222222222222222222222222222222222222"],
                  "shortId": "11111111",
                  "title": "feat: 添加示例功能"
                },
                "defaultBranch": false,
                "name": "dev-20250101",
                "protected": false,
                "webUrl": "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp/tree/dev-20250101"
              },
              {
                "commit": { "id": "3333333333333333333333333333333333333333", "shortId": "33333333" },
                "defaultBranch": false,
                "name": "master",
                "protected": true,
                "webUrl": "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp/tree/master"
              }
            ]
            """
        ))

        let branches = try await Self.makeService(api: api).getBranches(repositoryId: 8000001)

        #expect(branches.map(\.name) == ["dev-20250101", "master"])
        #expect(branches.map(\.defaultBranch) == [false, false])
        #expect(branches.map(\.protected) == [false, true], "protected 是布尔字段，照着读")
    }

    @Test("真实仓库报文能解码，并且不吃掉 archived 的仓库")
    func realRepositoryPayloadDecodes() async throws {
        // 真实列表里大量仓库 `archived: true`。归档不等于没有分支 ——
        // 只要它在列表里，就照常参与匹配与取分支。
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .success(
            """
            [
              {
                "accessLevel": 30,
                "archived": false,
                "createdAt": "2024-04-08T15:06:00+08:00",
                "creatorId": 9000001,
                "demoProject": false,
                "description": "app 项目",
                "encrypted": false,
                "httpUrlToRepo": "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp.git",
                "id": 8000001,
                "name": "ExampleApp",
                "nameWithNamespace": "\(Self.org) / example-group / ExampleApp",
                "namespaceId": 9000002,
                "path": "ExampleApp",
                "pathWithNamespace": "\(Self.org)/example-group/ExampleApp",
                "repositoryTags": [],
                "sshUrlToRepo": "git@codeup.aliyun.com:\(Self.org)/example-group/ExampleApp.git",
                "starCount": 1,
                "starred": false,
                "visibility": "private",
                "webUrl": "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp"
              }
            ]
            """
        ))

        let repositories = try await Self.makeService(api: api).getRepositories()

        let repository = try #require(repositories.first)
        #expect(repository.id == 8000001, "id 是数字，不是字符串")
        #expect(repository.name == "ExampleApp")
        #expect(repository.webUrl == "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp")
        #expect(repository.pathWithNamespace == "\(Self.org)/example-group/ExampleApp")

        // 与流水线里的地址（带 .git）对上 —— 这正是界面能不能列出分支的关键一步。
        let matched = try #require(RepositoryMatcher.match(
            pipelineRepo: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp.git",
            repositories: repositories
        ))
        #expect(matched.id == 8000001)
    }

    // MARK: - 错误传播

    @Test("401 原样抛成「Token 无效」，不被吞成空列表")
    func unauthorizedIsPropagated() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .failure(.unauthorized))

        await #expect(throws: APIError.unauthorized) {
            _ = try await Self.makeService(api: api).getRepositories()
        }
    }

    @Test("404 原样抛出，不被吞成空列表")
    func notFoundIsPropagated() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.repositoriesPath, .failure(.notFound))

        await #expect(throws: APIError.notFound) {
            _ = try await Self.makeService(api: api).getRepositories()
        }
    }

    @Test("响应体结构不对时报解析失败，而不是静默返回空列表")
    func decodingFailureIsPropagated() async throws {
        let api = StubAPIClient()
        // 仓库列表期待裸数组，这里给一个对象 —— 就是"服务端改了外层结构"那种回归。
        api.stub(path: Self.repositoriesPath, .success(#"{"data":[]}"#))

        await #expect(throws: APIError.self) {
            _ = try await Self.makeService(api: api).getRepositories()
        }
    }
}
