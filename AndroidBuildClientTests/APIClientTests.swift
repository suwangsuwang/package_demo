import Foundation
import Testing

@testable import AndroidBuildClient

/// `APIClient` 的行为测试。
///
/// 用 `StubURLProtocol` 截住 `URLSession`，因此断言的是 **APIClient 真正发出的请求**
/// 和 **它真正抛出的错误**，而不是某个自造替身的行为。
///
/// `.serialized`：桩状态是进程级的，用例之间必须串行。
@Suite("APIClient", .serialized)
struct APIClientTests {

    private static let token = "unit-test-token"

    /// 造一个已配置好 Token 的客户端。
    ///
    /// 同时返回具体类型与协议存在体：`send(_:) -> String` 等便利重载定义在
    /// `APIClientProtocol` 的扩展里，只有按协议类型调用才可见。
    private func makeClient(
        keychain: any KeychainServiceProtocol = MockKeychain(),
        token: String? = APIClientTests.token
    ) throws -> (client: APIClient, api: any APIClientProtocol, keychain: any KeychainServiceProtocol) {
        if let token, let mock = keychain as? MockKeychain {
            try mock.saveToken(token)
        }
        let client = APIClient(session: StubURLProtocol.makeSession(), keychain: keychain)
        return (client, client, keychain)
    }

    private func request(
        path: String = "/oapi/v1/platform/user",
        method: String = "GET"
    ) -> URLRequest {
        URLRequest(url: URL(string: "https://example.invalid\(path)")!)
        // 造完后补上 method（URLRequest(url:) 默认 GET，这里显式一些）
        .withMethod(method)
    }

    // MARK: - Token 注入

    @Test("Token 被注入 x-yunxiao-token 请求头")
    func injectsTokenHeader() async throws {
        StubURLProtocol.stub(.json("{}"))
        let (client, _, _) = try makeClient()

        _ = try await client.send(request(), decoding: EmptyResponse.self)

        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-yunxiao-token") == Self.token)
    }

    @Test("Token 不会出现在 URL 里")
    func tokenNeverAppearsInURL() async throws {
        StubURLProtocol.stub(.json("{}"))
        let (client, _, _) = try makeClient()

        _ = try await client.send(request(), decoding: EmptyResponse.self)

        let url = StubURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(!url.contains(Self.token), "Token 出现在 URL 中：\(url)")
    }

    @Test("每个请求都重新读一次 Keychain，不缓存 Token")
    func readsTokenPerRequest() async throws {
        StubURLProtocol.stub(.json("{}"))
        let mock = MockKeychain()
        let (client, _, _) = try makeClient(keychain: mock)

        _ = try await client.send(request(), decoding: EmptyResponse.self)
        let afterFirst = mock.loadCount
        _ = try await client.send(request(), decoding: EmptyResponse.self)

        #expect(mock.loadCount > afterFirst, "Token 被缓存了，没有每次现读")
    }

    @Test("换掉 Keychain 里的 Token 后，下一个请求用的是新值")
    func picksUpRotatedToken() async throws {
        StubURLProtocol.stub(.json("{}"))
        let mock = MockKeychain()
        let (client, _, _) = try makeClient(keychain: mock)

        _ = try await client.send(request(), decoding: EmptyResponse.self)
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-yunxiao-token") == Self.token)

        try mock.saveToken("rotated-token")
        _ = try await client.send(request(), decoding: EmptyResponse.self)

        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-yunxiao-token") == "rotated-token")
    }

    @Test("不会顺手写出其它认证头")
    func writesNoOtherAuthHeaders() async throws {
        StubURLProtocol.stub(.json("{}"))
        let (client, _, _) = try makeClient()

        _ = try await client.send(request(), decoding: EmptyResponse.self)

        let headers = StubURLProtocol.lastRequest?.allHTTPHeaderFields ?? [:]
        #expect(client.tokenHeaderFields == ["x-yunxiao-token"])
        #expect(Set(headers.keys) == ["x-yunxiao-token"])
    }

    @Test("Method 与路径原样透传，不被网络层改写")
    func preservesMethodAndPath() async throws {
        StubURLProtocol.stub(.json("{}"))
        let (client, _, _) = try makeClient()

        _ = try await client.send(
            request(path: "/oapi/v1/flow/organizations/1/pipelines/2/runs", method: "POST"),
            decoding: EmptyResponse.self
        )

        #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/oapi/v1/flow/organizations/1/pipelines/2/runs")
    }

    // MARK: - 缺 Token

    @Test("Keychain 中无 Token 时抛 missingToken，且不发请求")
    func missingTokenThrowsWithoutSending() async throws {
        StubURLProtocol.stub(.json("{}"))
        let (client, _, _) = try makeClient(keychain: MockKeychain(), token: nil)

        await #expect(throws: APIError.missingToken) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
        #expect(StubURLProtocol.seenRequests.isEmpty, "缺少 Token 时不应发出请求")
    }

    @Test("Token 是空白串时同样视为缺失")
    func blankTokenThrows() async throws {
        StubURLProtocol.stub(.json("{}"))
        let mock = MockKeychain()
        try mock.saveToken("   \n ")
        let client = APIClient(session: StubURLProtocol.makeSession(), keychain: mock)

        await #expect(throws: APIError.missingToken) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("Keychain 读取失败时抛错，不回退成无认证请求")
    func keychainFailureDoesNotSkipAuth() async throws {
        StubURLProtocol.stub(.json("{}"))
        let client = APIClient(session: StubURLProtocol.makeSession(), keychain: FailingKeychain())

        await #expect(throws: (any Error).self) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
        #expect(StubURLProtocol.seenRequests.isEmpty, "认证信息取不到时不应发出请求")
    }

    // MARK: - 状态码

    @Test("401 归类为 unauthorized")
    func unauthorizedOn401() async throws {
        StubURLProtocol.stub(.json(#"{"message":"bad token"}"#, statusCode: 401))
        let (client, _, _) = try makeClient()

        await #expect(throws: APIError.unauthorized) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("403 同样归类为 unauthorized")
    func unauthorizedOn403() async throws {
        StubURLProtocol.stub(.json("{}", statusCode: 403))
        let (client, _, _) = try makeClient()

        await #expect(throws: APIError.unauthorized) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("404 归类为 notFound，提示指向配置检查")
    func notFoundOn404() async throws {
        StubURLProtocol.stub(.json("{}", statusCode: 404))
        let (client, _, _) = try makeClient()

        await #expect(throws: APIError.notFound) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("429 归类为 rateLimited")
    func rateLimitedOn429() async throws {
        StubURLProtocol.stub(.json("{}", statusCode: 429))
        let (client, _, _) = try makeClient()

        await #expect(throws: APIError.rateLimited) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("5xx 归类为 serverError 并保留状态码")
    func serverErrorOn5xx() async throws {
        StubURLProtocol.stub(.json("{}", statusCode: 503))
        let (client, _, _) = try makeClient()

        await #expect(throws: APIError.serverError(503)) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("未归类的错误码保留在 httpStatus 里")
    func otherStatusCodesArePreserved() async throws {
        StubURLProtocol.stub(.json("{}", statusCode: 418))
        let (client, _, _) = try makeClient()

        await #expect(throws: APIError.httpStatus(418)) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }
    }

    @Test("2xx 之外的响应体被整段丢弃，不回显服务端内容")
    func errorBodyIsDiscarded() async throws {
        // 服务端在出错响应里回显了请求上下文（这里放一段哨兵文本模拟）。
        StubURLProtocol.stub(.json(#"{"echo":"server-side-secret-echo"}"#, statusCode: 401))
        let (client, _, _) = try makeClient()

        let error = await #expect(throws: APIError.self) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }

        let text = error?.localizedDescription ?? ""
        #expect(!text.contains("server-side-secret-echo"), "错误信息回显了服务端响应体")
        #expect(!text.contains(Self.token), "错误信息包含 Token")
    }

    // MARK: - 解码与文本

    @Test("2xx 响应按 Codable 解码")
    func decodesJSONBody() async throws {
        StubURLProtocol.stub(.json(#"{"name":"tester","id":7}"#))
        let (client, _, _) = try makeClient()

        struct User: Decodable, Sendable {
            let name: String
            let id: Int
        }

        let user = try await client.send(request(), decoding: User.self)

        #expect(user.name == "tester")
        #expect(user.id == 7)
    }

    @Test("解码失败归为 decodingFailed")
    func decodeFailureIsReported() async throws {
        StubURLProtocol.stub(.json(#"{"name":42}"#))
        let (client, _, _) = try makeClient()

        struct User: Decodable, Sendable { let name: String }

        await #expect(throws: APIError.self) {
            _ = try await client.send(request(), decoding: User.self)
        }
    }

    @Test("文本接口返回原文")
    func returnsRawText() async throws {
        StubURLProtocol.stub(.json("line one\nline two"))
        let (_, api, _) = try makeClient()

        // `send` 同时存在「原始响应」与「文本」两个重载，这里显式标注结果类型来消歧。
        let text: String = try await api.send(request())

        #expect(text == "line one\nline two")
    }

    @Test("非 UTF-8 响应体归为 invalidTextEncoding")
    func invalidTextEncodingIsReported() async throws {
        StubURLProtocol.stub(.init(statusCode: 200, body: Data([0xFF, 0xFE, 0xFF])))
        let (_, api, _) = try makeClient()

        await #expect(throws: APIError.invalidTextEncoding) {
            let _: String = try await api.send(request())
        }
    }

    @Test("原始 send 不做状态码判定，由调用方自行处理")
    func rawSendSkipsStatusCheck() async throws {
        StubURLProtocol.stub(.json(#"{"status":"FAILED"}"#, statusCode: 500))
        let (_, api, _) = try makeClient()

        let raw: (data: Data, response: HTTPURLResponse) = try await api.send(request())

        #expect(raw.response.statusCode == 500)
    }

    // MARK: - 传输层

    @Test("超时归为 network")
    func timeoutIsNetworkError() async throws {
        StubURLProtocol.fail(.timedOut)
        let (client, _, _) = try makeClient()

        let error = await #expect(throws: APIError.self) {
            _ = try await client.send(request(), decoding: EmptyResponse.self)
        }

        guard case .network = error else {
            Issue.record("期望 .network，实际是 \(String(describing: error))")
            return
        }
    }

    // MARK: - Token 不泄入错误信息

    @Test("任何错误描述都不包含 Token")
    func noErrorDescriptionContainsToken() async throws {
        let errors: [APIError] = [
            .missingToken,
            .invalidURL("/oapi/v1/platform/user"),
            .invalidResponse,
            .httpStatus(418),
            .unauthorized,
            .notFound,
            .rateLimited,
            .serverError(503),
            .invalidTextEncoding,
            .decodingFailed("keyNotFound"),
            .network("URLError -1001"),
            .configurationMissing("organizationId"),
        ]

        for error in errors {
            #expect(
                !error.localizedDescription.contains(Self.token),
                "错误描述包含 Token：\(error.localizedDescription)"
            )
        }
    }

    @Test("401 的提示语指向重新填写 Token，且可被 UI 识别为认证失败")
    func unauthorizedMessageIsActionable() {
        let error = APIError.unauthorized

        #expect(error.isAuthenticationFailure)
        #expect(error.localizedDescription.contains("Token"))
        #expect(!error.localizedDescription.contains(Self.token))
    }

    @Test("只有缺 Token 与 401/403 算认证失败")
    func authenticationFailureClassification() {
        #expect(APIError.missingToken.isAuthenticationFailure)
        #expect(APIError.unauthorized.isAuthenticationFailure)
        #expect(!APIError.notFound.isAuthenticationFailure)
        #expect(!APIError.rateLimited.isAuthenticationFailure)
        #expect(!APIError.serverError(503).isAuthenticationFailure)
        #expect(!APIError.httpStatus(418).isAuthenticationFailure)
        #expect(!APIError.network("URLError -1001").isAuthenticationFailure)
    }
}

// MARK: - 小工具

private extension URLRequest {
    /// 只为让测试里的请求构造读起来更直白。
    func withMethod(_ method: String) -> URLRequest {
        var copy = self
        copy.httpMethod = method
        return copy
    }
}
