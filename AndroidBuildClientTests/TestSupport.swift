import Foundation
import Synchronization

@testable import AndroidBuildClient

// MARK: - 内存 Keychain

/// 内存版 Keychain，用于在不碰真实钥匙串的前提下测试 `TokenStore` / `APIClient`。
///
/// 用 `Mutex` 而不是 `@unchecked Sendable` —— 后者在生产代码里被明令禁止，
/// 测试代码同样按这个标准要求自己（它同样会被编译器放在并发环境里）。
final class MockKeychain: KeychainServiceProtocol, Sendable {

    private let storage = Mutex<String?>(nil)
    private let loadCalls = Mutex<Int>(0)
    private let saveCalls = Mutex<Int>(0)

    /// 读取次数。用于验证「每次请求都现读 Token，而不是缓存」。
    var loadCount: Int { loadCalls.withLock { $0 } }
    /// 写入次数。
    var saveCount: Int { saveCalls.withLock { $0 } }

    func saveToken(_ token: String) throws {
        saveCalls.withLock { $0 += 1 }
        storage.withLock { $0 = token }
    }

    func loadToken() throws -> String? {
        loadCalls.withLock { $0 += 1 }
        return storage.withLock { $0 }
    }

    func deleteToken() throws {
        storage.withLock { $0 = nil }
    }
}

/// 读得到、但永远抛错的 Keychain —— 覆盖 Keychain 故障路径。
struct FailingKeychain: KeychainServiceProtocol {
    func saveToken(_ token: String) throws { throw KeychainError.unexpectedStatus(-1) }
    func loadToken() throws -> String? { throw KeychainError.unexpectedStatus(-1) }
    func deleteToken() throws { throw KeychainError.unexpectedStatus(-1) }
}

// MARK: - 空响应体

/// 「只关心状态码、不关心响应体」的用例用它替代具体的业务模型，
/// 免得为了 19 处 `send` 去挑一个真实的 Decodable 类型。
struct EmptyResponse: Decodable, Sendable {}

// MARK: - Codeup 接口替身

/// 固定的 Codeup 应答：一份仓库列表 + 一份分支列表。
///
/// 存在的理由与 `StubAPIClient` 相同 —— 让 `BuildViewModel` 的用例不必
/// 依赖磁盘上的真实配置文件，也不必真的去请求 Codeup。分支列表是这一层
/// 唯一被断言的输入：**触发时用的分支必须来自这里（即接口），
/// 而不是任何写死的默认值**，所以它在测试里必须是可控的。
///
/// `Mutex` 而不是可变类属性：`CodeupServiceProtocol` 要求 `Sendable`。
final class StubCodeupService: CodeupServiceProtocol, Sendable {

    private struct State: Sendable {
        var repositories: [CodeupRepository]
        var branches: [CodeupBranch]
        var repositoriesError: (any Error)?
        var branchesError: (any Error)?
        var requestedRepositoryIDs: [Int] = []
    }

    private let state: Mutex<State>

    init(
        repositories: [CodeupRepository] = [StubCodeupService.defaultRepository],
        branches: [CodeupBranch] = StubCodeupService.defaultBranches,
        repositoriesError: (any Error)? = nil,
        branchesError: (any Error)? = nil
    ) {
        state = Mutex(State(
            repositories: repositories,
            branches: branches,
            repositoriesError: repositoriesError,
            branchesError: branchesError
        ))
    }

    /// 与 `BuildViewModelTests.repoURL` 对得上的那个仓库。
    static let defaultRepository = CodeupRepository(
        id: 8000001,
        name: "ExampleApp",
        webUrl: "https://codeup.aliyun.com/example-org-id/example-group/ExampleApp",
        pathWithNamespace: "example-org-id/example-group/ExampleApp"
    )

    /// 默认分支 + 一个**带斜杠的真实分支名**。
    ///
    /// 带斜杠的那一个不是装饰：它是"本地用枚举表示分支"时最先丢掉的形态，
    /// 界面上必须能显示它、选中它、并原样发进请求体。
    static let defaultBranches: [CodeupBranch] = [
        CodeupBranch(name: "test", defaultBranch: true, protected: false),
        CodeupBranch(name: "release/release-20250101", defaultBranch: false, protected: false),
    ]

    /// 请求过分支的仓库 ID，按顺序排列。
    var requestedRepositoryIDs: [Int] {
        state.withLock { $0.requestedRepositoryIDs }
    }

    func getRepositories() async throws -> [CodeupRepository] {
        let error = state.withLock { $0.repositoriesError }
        if let error { throw error }
        return state.withLock { $0.repositories }
    }

    func getBranches(repositoryId: Int) async throws -> [CodeupBranch] {
        let error = state.withLock { state -> (any Error)? in
            state.requestedRepositoryIDs.append(repositoryId)
            return state.branchesError
        }
        if let error { throw error }
        return state.withLock { $0.branches }
    }
}

// MARK: - 构建结果服务替身

/// 固定的 `BuildResult`（或一个固定错误），并记录每一次调用的入参。
///
/// 存在的理由与 `StubCodeupService` 相同 —— `BuildResultViewModel` 的用例
/// 不该为了取一份结果就去拼六七个接口路径的应答；这一层要断言的是
/// **状态怎么映射到界面**，而不是 `BuildService` 内部那条链路
/// （那条链路由 `BuildServiceTests` 覆盖）。
///
/// 记录入参是必须的：`pipelineId` 标明这次运行属于哪条流水线，传错了不会
/// 编译失败，只会静默地展示另一条流水线的结果，所以它必须能被断言。
///
/// `Mutex` 而不是可变类属性：`BuildServiceProtocol` 要求 `Sendable`。
final class StubBuildService: BuildServiceProtocol, Sendable {

    /// 一次调用收到的入参，按顺序排列。
    struct Call: Sendable, Equatable {
        var pipelineRunId: Int
        var pipelineId: String
    }

    private struct State: Sendable {
        var result: BuildResult
        /// 抛错路径。与 `result` 互斥 —— 有它就不会返回结果。
        var error: (any Error)?
        var calls: [Call] = []
    }

    private let state: Mutex<State>

    init(result: BuildResult, error: (any Error)? = nil) {
        state = Mutex(State(result: result, error: error))
    }

    /// 依次收到的全部调用。
    var calls: [Call] { state.withLock { $0.calls } }

    var callCount: Int { state.withLock { $0.calls.count } }

    /// 依次收到的 `pipelineRunId`。
    var receivedPipelineRunIds: [Int] { calls.map(\.pipelineRunId) }

    /// 依次收到的 `pipelineId`。
    var receivedPipelineIds: [String] { calls.map(\.pipelineId) }

    /// 让后续调用改为返回结果 —— 用于「第一次失败、重试成功」这类跨次用例。
    func clearError() {
        state.withLock { $0.error = nil }
    }

    func fetchBuildResult(
        pipelineRunId: Int,
        pipelineId: String
    ) async throws -> BuildResult {
        let error = state.withLock { state -> (any Error)? in
            state.calls.append(Call(pipelineRunId: pipelineRunId, pipelineId: pipelineId))
            return state.error
        }
        if let error { throw error }
        return state.withLock { $0.result }
    }
}

// MARK: - 记录请求的 APIClient 替身
/// 按「路径 → 响应」返回结果的 `APIClientProtocol` 替身。
///
/// 它存在的意义是**记录 `FlowService` 实际请求了哪些路径** ——
/// 路径拼接错误（例如运行详情误用 `/pipelineRuns/{id}`）不会让编译失败，
/// 只会在真机上表现为 404，因此必须在测试里把路径钉死。
///
/// 顺带绕开 `URLSession`：`FlowService` 只做路径拼接与字段映射，
/// 用不到真实网络。
///
/// 注意：**这里不检查认证头**。`FlowService` 职责边界内根本不接触 Token，
/// 认证头的有无由 `APIClientTests` 对着真实 `APIClient` 的请求断言。
final class StubAPIClient: APIClientProtocol {

    /// 一次应答。`.failure` 用来覆盖错误分支。
    ///
    /// `.success` 与 `.successWithHeaders` 分开，而不是给 `.success` 加一个
    /// 默认空字典的参数：**没有响应头的应答和有响应头的应答是两种不同的行为**。
    /// 分页恰恰是靠响应头驱动的（`x-next-page` / `x-total-pages` / `x-total`），
    /// 用一个"顺手带上头"的重载会让"这个用例到底有没有提供分页头"
    /// 在阅读时看不出来 —— 而它决定了被测代码走的是翻页还是兜底分支。
    enum Reply: Sendable {
        case success(String)
        /// 带自定义响应头的成功应答。用于分页。
        case successWithHeaders(String, headers: [String: String])
        case failure(APIError)
        case transportFailure(any Error)
    }

    private struct State: Sendable {
        /// 按 `"METHOD path"` 索引的应答。
        var methodRoutes: [String: Reply] = [:]
        /// 按路径索引的应答，**不区分方法** —— 「这个路径怎么回都行」时用它。
        var routes: [String: Reply] = [:]
        var sequences: [String: [Reply]] = [:]
        var fallback: Reply?
        var seen: [URLRequest] = []
    }

    private let state = Mutex(State())

    private static func key(_ method: String, _ path: String) -> String { "\(method) \(path)" }

    // MARK: 装配

    /// 精确匹配某个路径，**不区分方法**。
    func stub(path: String, _ reply: Reply) {
        state.withLock { $0.routes[path] = reply }
    }

    /// 精确匹配某个「方法 + 路径」。
    ///
    /// 触发打包与历史记录**共用同一个路径**（`…/pipelines/{id}/runs`），
    /// 靠方法区分：`POST` 触发、`GET` 查历史。只按路径 stub 的话，
    /// 触发和查历史会拿到同一份应答 —— 于是「触发返回裸数字 41」会被当成
    /// 历史记录去解码，解析失败被静默吞掉，看起来像"历史接口坏了"。
    func stub(method: String, path: String, _ reply: Reply) {
        state.withLock { $0.methodRoutes[Self.key(method, path)] = reply }
    }

    /// 同一路径按顺序返回不同的应答；用完之后一直返回最后一个。
    ///
    /// 用于「第一次读不到、第二次才读到」这类**随时间变化**的接口行为 ——
    /// 日志刷盘就是典型：状态已经是 SUCCESS，但末尾几行还没落定。
    /// 没有这个能力的话，"重试"这件事在测试里根本表达不出来，
    /// 只能靠真机跑一次去看。
    func stubSequence(path: String, _ replies: [Reply]) {
        precondition(!replies.isEmpty, "序列至少要有一个应答")
        state.withLock { $0.sequences[path] = replies }
    }

    /// 所有未单独指定的路径都走它 —— 用于「不想关心路径，只想让流程走通」的用例。
    func stubEverything(_ reply: Reply) {
        state.withLock { $0.fallback = reply }
    }

    // MARK: 观测

    /// 依次被请求的路径。
    var requestedPaths: [String] {
        state.withLock { $0.seen.compactMap(\.url?.path) }
    }

    /// 依次被请求的 `(method, path)`。
    var requestedRoutes: [String] {
        state.withLock {
            $0.seen.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "")" }
        }
    }

    /// 最后一次请求的查询参数，按名字取值。
    ///
    /// `stepIndex` / `offset` / `limit` / `buildId` 这类参数写错了同样不会编译失败，
    /// 只会让服务端返回空日志，所以单独暴露出来断言。
    ///
    /// ⚠️ 取的是**最后一次**请求。若一次流程在目标请求之后还会再发别的请求
    /// （例如打包跑完后收尾时刷一次历史记录），这里会拿到那个收尾请求的空参数 ——
    /// 那种情况下用 `requestedQuery(forPath:)` 按路径定位，不要依赖顺序。
    var requestedQuery: [String: String] {
        state.withLock { Self.query(for: $0.seen.last?.url) }
    }

    /// 某个路径上最后一次请求的查询参数。
    ///
    /// 用于「这个请求不是整条流程的最后一步」的情况 —— 按路径找，
    /// 用例就不必去数"它是第几个请求"。
    func requestedQuery(forPath path: String) -> [String: String] {
        state.withLock { state in
            Self.query(for: state.seen.last { $0.url?.path == path }?.url)
        }
    }

    /// 某个路径上**每一次**请求的完整查询参数，按顺序排列。
    ///
    /// 翻页的断言需要它：`requestedQuery(forPath:)` 只给最后一次，
    /// 而"到底翻了哪几页"恰恰是一串值 —— 用它才能断出 `["1", "2", "3"]`。
    func requestedQueryValues(forPath path: String) -> [[String: String]] {
        state.withLock { state in
            state.seen
                .filter { $0.url?.path == path }
                .map { Self.query(for: $0.url) }
        }
    }

    /// 某个路径上每一次请求的某个查询参数，按顺序排列。
    func requestedQueryValues(forPath path: String, name: String) -> [String] {
        requestedQueryValues(forPath: path).compactMap { $0[name] }
    }

    private static func query(for url: URL?) -> [String: String] {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 最后一次请求的请求体。
    ///
    /// 触发打包的请求体是**唯一**一处"拼错了不会编译失败、只会静默地构建另一个
    /// 分支或环境"的地方 —— 它必须能被断言，否则选错分支这件事在测试里完全不可见。
    var requestedBody: Data? {
        state.withLock { $0.seen.last?.httpBody }
    }

    /// 最后一次请求体的 UTF-8 文本。用于对报文字形（而不只是字段取值）下断言。
    var requestedBodyText: String? {
        requestedBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 只带请求体的那些请求，按顺序排列。
    ///
    /// 目前唯一带 body 的接口就是触发打包。用它而不是"最后一次请求的 body"，
    /// 是因为一次完整流程的最后几个请求都是 GET，没有 body ——
    /// 取"最后一次"会拿到 `nil`，看起来像报文没发出去。
    var seenBodies: [Data] {
        state.withLock { $0.seen.compactMap(\.httpBody) }
    }

    // MARK: APIClientProtocol

    var tokenHeaderFields: [String] { ["x-yunxiao-token"] }

    func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let reply = state.withLock { state -> Reply? in
            state.seen.append(request)
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"

            // 序列优先：它表达的是"这个路径会随时间变化"，比固定应答更强的意图。
            if var queued = state.sequences[path], !queued.isEmpty {
                let next = queued.removeFirst()
                // 留最后一个备用，序列读完后就是"稳定状态"。
                state.sequences[path] = queued.isEmpty ? [next] : queued
                return next
            }
            // 方法精确匹配优先于只按路径匹配。
            return state.methodRoutes[Self.key(method, path)]
                ?? state.routes[path]
                ?? state.fallback
        }

        switch reply {
        case .success(let body):
            return (Data(body.utf8), Self.response(for: request, headers: [:]))
        case .successWithHeaders(let body, let headers):
            return (Data(body.utf8), Self.response(for: request, headers: headers))
        case .failure(let error):
            throw error
        case .transportFailure(let error):
            throw error
        case nil:
            throw APIError.notFound
        }
    }

    private static func response(for request: URLRequest, headers: [String: String]) -> HTTPURLResponse {
        var fields = headers
        fields["Content-Type"] = "application/json"
        return HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )!
    }
}

// MARK: - URLProtocol 桩

/// 拦截 `URLSession` 的请求，让 `APIClient` 的测试完全不经过网络。
///
/// 关键点：这里能拿到 **APIClient 实际发出的 `URLRequest`**，
/// 因此「Token 有没有正确注入请求头」「Token 有没有被塞进 URL」都是对真实行为的断言，
/// 而不是对某段自造实现的断言。
/// 注意：这里不声明 `Sendable` —— `URLProtocol` 本身不是 `Sendable`，
/// 需要跨线程共享的只有下面的 `Mutex` 静态状态。
final class StubURLProtocol: URLProtocol {

    /// 一次请求的应答。
    struct Response: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]

        static func json(_ text: String, statusCode: Int = 200) -> Response {
            Response(
                statusCode: statusCode,
                body: Data(text.utf8),
                headers: ["Content-Type": "application/json"]
            )
        }

        func asHTTPResponse(for url: URL?) -> HTTPURLResponse {
            HTTPURLResponse(
                url: url ?? URL(string: "https://example.invalid")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        }
    }

    /// 应答与传输层错误二者互斥。
    enum Behavior: Sendable {
        case respond(Response)
        case fail(URLError.Code)
    }

    private struct State: Sendable {
        var behavior: Behavior?
        var seen: [URLRequest] = []
    }

    private static let state = Mutex(State())

    static func stub(_ behavior: Behavior) {
        state.withLock { $0 = State(behavior: behavior, seen: []) }
    }

    static func stub(_ response: Response) { stub(.respond(response)) }
    static func fail(_ code: URLError.Code) { stub(.fail(code)) }

    /// 被拦截到的请求，按顺序排列。
    static var seenRequests: [URLRequest] { state.withLock { $0.seen } }
    static var lastRequest: URLRequest? { seenRequests.last }

    /// 供测试直接构造的应答参数透传。
    static func reset() { state.withLock { $0 = State() } }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let behavior = Self.state.withLock { state -> Behavior? in
            state.seen.append(request)
            return state.behavior
        }

        guard let behavior else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch behavior {
        case .respond(let stub):
            client?.urlProtocol(
                self,
                didReceive: stub.asHTTPResponse(for: request.url),
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

extension StubURLProtocol {

    /// 挂上桩的 `URLSession`。每次调用都用新的配置，避免协议注册相互影响。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
