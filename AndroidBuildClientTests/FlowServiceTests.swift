import Foundation
import Testing

@testable import AndroidBuildClient

/// `FlowService` 的路径与解析测试。
///
/// 这里断言的核心是**路径字形**，因为它是整条链路里唯一"写错了也照样编译通过"的部分：
/// 运行详情用了 `/pipelineRuns/{id}`，真机上只会得到一句
/// "接口地址不存在（HTTP 404）…请检查 Yunxiao 域名与流水线 ID 配置"，
/// 排查方向会被完全带偏。
///
/// 不碰网络：`StubAPIClient` 按路径回放应答。
@Suite("FlowService")
struct FlowServiceTests {

    private static let org = "example-org-id"
    private static let pipeline = "5000001"
    private static let base = "/oapi/v1/flow/organizations/\(org)/pipelines/\(pipeline)"

    /// 一个**两个环境指向不同流水线**的配置。
    ///
    /// ⚠️ 这份配置不是装饰。当前生产的配置文件里 `test` 与 `release` 恰好指向同一条
    /// 流水线（都是 \(pipeline)），而"环境推不出流水线"这个 bug 恰恰只在两者不同时
    /// 才暴露 —— 用同一份配置去断言，把 `environment` 传错成 `pipelineId` 也照样通过。
    private static let splitPipelines = ["test": "111", "release": "222"]

    private static let config = BuildConfig(
        yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
        organizationId: org,
        pipelines: ["test": pipeline, "release": pipeline]
    )

    private static let splitConfig = BuildConfig(
        yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
        organizationId: org,
        pipelines: splitPipelines
    )

    /// 一个用固定配置的 `FlowService`（不读磁盘上的真实配置文件）。
    private func makeService(
        api: StubAPIClient,
        config: BuildConfig? = nil
    ) -> FlowService {
        let resolved = config ?? Self.config
        return FlowService(api: api, config: { resolved })
    }

    // MARK: - 触发运行

    /// 触发一次打包需要**两个**应答：流水线详情（拿仓库地址）与触发本身。
    ///
    /// 把「详情 + 触发」这一对路径绑在一起 stub，是为了让每个用例都只关心
    /// 自己想断言的东西 —— 触发前必须取详情这件事是**规定动作**，不是巧合。
    private func stubTrigger(api: StubAPIClient, returning body: String) {
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .success(body))
    }

    @Test("触发打包后拿到的是响应里的裸数字，不做任何猜测")
    func triggerReturnsTheIDFromTheResponse() async throws {
        let api = StubAPIClient()
        stubTrigger(api: api, returning: "33")

        let trigger = try await makeService(api: api)
            .runPipeline(branch: "test", environment: .test)

        #expect(trigger.pipelineRunId == 33)
        // 详情在先、触发在后：仓库地址只能从详情里拿，顺序反了就拿不到键。
        #expect(api.requestedRoutes == ["GET \(Self.base)", "POST \(Self.base)/runs"])
    }

    @Test("触发请求体是 `params` 包裹的 JSON 字符串，键是仓库地址而不是写死的常量")
    func triggerBodyIsAJSONStringKeyedByRepoURL() async throws {
        let api = StubAPIClient()
        stubTrigger(api: api, returning: "33")

        _ = try await makeService(api: api).runPipeline(branch: "test", environment: .release)

        let body = try #require(api.requestedBodyText, "触发请求没带请求体")

        // 外层就是一个对象，里面只有一个 `params`。
        struct Envelope: Decodable { let params: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(body.utf8))

        // ⚠️ `params` 的值是**一段 JSON 文本**，不是嵌套对象 ——
        // 断言这一点，别"顺手优化"成嵌套对象：服务端会拒收，
        // 而错误信息看起来像参数值写错了，不会指向"嵌套层级不对"。
        // 表现为外层报文里出现被转义的引号（`\"`）。
        #expect(envelope.params.hasPrefix("{"), "params 不是 JSON 文本：\(envelope.params)")
        #expect(envelope.params.hasSuffix("}"), "params 不是 JSON 文本：\(envelope.params)")
        #expect(body.contains(#"\""#), "params 没有被转义成字符串嵌进外层：\(body)")

        let params = try #require(envelope.params.data(using: .utf8))

        struct Params: Decodable {
            let runningBranchs: [String: String]
            let envs: [String: String]
        }
        let decoded = try JSONDecoder().decode(Params.self, from: params)

        // 键是**从流水线详情读出来的**仓库地址，不是任何写死的字符串。
        #expect(decoded.runningBranchs == [Self.repoURL: "test"])
        #expect(decoded.envs == ["env": "release"])
    }

    /// 分支与环境的**全部四种组合**都必须能表达出来。
    ///
    /// 这不是凑数：`branch=test` + `env=release` 正是已经用实际请求验证过的组合，
    /// 也是"把分支和环境合并成一个字段"这种设计最先丢掉的那一种。
    /// 合并之后另外三种组合照常通过，只有它表达不出来 —— 所以矩阵必须完整跑。
    ///
    /// ⚠️ 分支用**真实的、带斜杠的**分支名而不是 `test` / `release` 这类短词：
    /// 分支名里出现 `/` 是完全正常的（`release/release-20250101`），
    /// 而它恰好是"本地用枚举表示分支"最先丢掉的形态 —— 那个枚举根本写不出这个值。
    /// 这里顺带把"斜杠分支名要能原样穿过 JSON 编码"钉住。
    @Test("分支与环境是独立参数，四种组合都要能表达")
    func branchAndEnvironmentAreIndependent() async throws {
        struct Params: Decodable {
            let runningBranchs: [String: String]
            let envs: [String: String]
        }

        for (branch, environment) in [
            ("test", AppConfiguration.Environment.test),
            ("test", AppConfiguration.Environment.release),
            ("release", AppConfiguration.Environment.test),
            ("release/release-20250101", AppConfiguration.Environment.release),
        ] {
            let api = StubAPIClient()
            stubTrigger(api: api, returning: "33")

            _ = try await makeService(api: api)
                .runPipeline(branch: branch, environment: environment)

            let body = try #require(api.requestedBodyText)
            struct Envelope: Decodable { let params: String }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(body.utf8))
            let params = try #require(envelope.params.data(using: .utf8))
            let decoded = try JSONDecoder().decode(Params.self, from: params)

            let label = "分支 \(branch) / 环境 \(environment.rawValue)"
            #expect(decoded.runningBranchs == [Self.repoURL: branch], "\(label)：分支没传对")
            #expect(decoded.envs == ["env": environment.rawValue], "\(label)：环境没传对")
        }
    }

    /// 报文形状与接口文档给的示例对齐。
    ///
    /// 上一条用例验的是"字段取值对不对"，这一条验的是"报文长什么样"。
    /// 分开的理由：报文形状错了（例如 `params` 被写成嵌套对象而不是字符串）
    /// 不会编译失败、也不会让服务端回一句"参数错误" —— 它会被当成没传参数，
    /// 于是静默地按流水线默认分支构建。这与远端刚修掉的那个 bug 是同一类故障：
    /// 用户以为选了分支，实际没选，而界面上一路显示"构建成功"。
    ///
    /// 因此这里把整段报文写死。将来任何人"顺手优化"报文形状（改成嵌套对象、
    /// 改字段名、把 `params` 的转义去掉），都会在这里红。
    ///
    /// ⚠️ **与文档示例的差别只有一处，且无意义：`/` 的转义层数。**
    /// `JSONEncoder` 默认把 `/` 编码成 `\/`（合法且等价于 `/`）；内层已经是
    /// `\/`，再被外层转义一层就成了 `\\\/`。文档示例写的是 `\/`。
    /// 两者解析出来的字符串**逐字符相同**（见上一条用例的解码断言），
    /// 服务端也一直接受这种写法 —— 所以这里锁的是**字节**，不是语义，
    /// 目的只是让"报文形状被改动"这件事可见。想让它与文档逐字节一致，
    /// 给编码器加 `.withoutEscapingSlashes` 即可；但那是**纯外观**改动，
    /// 而当前写法已经在真实服务端上跑通过，不做无谓改动。
    @Test("触发报文形状被钉住：`params` 是转义后的 JSON 字符串，不是嵌套对象")
    func triggerBodyShapeIsPinned() async throws {
        let api = StubAPIClient()
        stubTrigger(api: api, returning: "33")

        _ = try await makeService(api: api).runPipeline(
            branch: "release/release-20250101",
            environment: .release
        )

        let body = try #require(api.requestedBodyText, "触发请求没带请求体")

        // 用原始字符串字面量（`#"""`）：报文里全是反斜杠，
        // 不用原始字面量的话每一层转义都得再翻一倍，改起来极易出错。
        let expected = #"""
        {"params":"{\"envs\":{\"env\":\"release\"},\"runningBranchs\":{\"https:\\\/\\\/codeup.aliyun.com\\\/example-org-id\\\/example-group\\\/ExampleApp.git\":\"release\\\/release-20250101\"}}"}
        """#

        #expect(
            body == expected,
            """
            触发报文形状变了。
            实际：\(body)
            期望：\(expected)
            """
        )

        // 单拎出来强调一次关键的形状约束，免得上面那行长字符串的差异被忽略：
        // `params` 的值必须以 `{` 开头（是 JSON **文本**），且外层带有转义引号。
        struct Envelope: Decodable { let params: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(body.utf8))
        #expect(envelope.params.hasPrefix("{"), "params 不是 JSON 文本：\(envelope.params)")
        #expect(body.contains(#"\""#), "params 没有被转义成字符串嵌进外层：\(body)")
    }

    @Test("流水线详情里没有代码源时不发触发请求，直接报缺仓库地址")
    func missingRepoURLStopsBeforeTriggering() async throws {
        let api = StubAPIClient()
        // 详情拿得到，但里面没有 sources。
        api.stub(
            path: Self.base,
            .success(#"{"name":"Example-App-Android","id":5000001,"pipelineConfigId":1,"pipelineConfig":{"version":35}}"#)
        )
        api.stub(path: "\(Self.base)/runs", .success("33"))

        let error = await #expect(throws: FlowServiceError.self) {
            _ = try await makeService(api: api).runPipeline(branch: "test", environment: .test)
        }

        guard case .missingIdentifier(let detail) = error else {
            Issue.record("期望 .missingIdentifier，实际是 \(String(describing: error))")
            return
        }
        #expect(detail.contains("repo"), "报错没指出缺的是哪个字段：\(detail)")
        // 关键：**没有**发出触发请求。宁可不打包，也不能发一个不带 body 的请求
        // 静默地按流水线默认分支构建 —— 那样用户以为选了分支，实际没选。
        #expect(
            api.requestedRoutes == ["GET \(Self.base)"],
            "缺仓库地址时不应发出触发请求，实际请求了：\(api.requestedRoutes)"
        )
    }

    @Test("连续两次触发拿到各自的 ID，互不影响")
    func consecutiveTriggersUseTheirOwnIDs() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .success("41"))
        let service = makeService(api: api)

        let first = try await service.runPipeline(branch: "test", environment: .test)
        api.stub(path: "\(Self.base)/runs", .success("42"))
        let second = try await service.runPipeline(branch: "test", environment: .test)

        #expect(first.pipelineRunId == 41)
        #expect(second.pipelineRunId == 42)
    }

    /// `runPipeline` 回传的 `pipelineId` 必须是**它自己实际拼进 POST 路径的那一个**。
    ///
    /// ⚠️ 用 `test → 111` / `release → 222` 这份配置，而不是生产里那两条**同号**的
    /// 流水线：同号时"回传环境对应的流水线"与"回传实际打的那条流水线"结果一样，
    /// 这条断言就退化成恒真。只有两个号不同，才验得出回传的值确实来自这次请求。
    ///
    /// 断言分两半，缺一不可：
    /// - 回传值 == 该环境配置的流水线号；
    /// - **这次真实发出的请求路径里也是那个号**（不是只看返回值自己说自己是几）。
    @Test("触发回传的 pipelineId 就是它实际发到的那条流水线")
    func triggerReturnsThePipelineIdItActuallyPostedTo() async throws {
        for (environment, expected) in [
            (AppConfiguration.Environment.test, "111"),
            (AppConfiguration.Environment.release, "222"),
        ] {
            let api = StubAPIClient()
            let base = "/oapi/v1/flow/organizations/\(Self.org)/pipelines/\(expected)"
            api.stub(path: base, .success(Self.pipelineInfoPayload))
            api.stub(path: "\(base)/runs", .success("33"))

            let trigger = try await makeService(api: api, config: Self.splitConfig)
                .runPipeline(branch: "test", environment: environment)

            let label = "环境 \(environment.rawValue)"
            #expect(trigger.pipelineId == expected, "\(label)：回传的 pipelineId 不对")
            #expect(trigger.pipelineRunId == 33, "\(label)：回传的运行 ID 不对")
            #expect(
                api.requestedRoutes == ["GET \(base)", "POST \(base)/runs"],
                "\(label)：请求没打到这条流水线上，实际请求了 \(api.requestedRoutes)"
            )
        }
    }

    @Test("响应不是裸数字时明确报解析失败，而不是悄悄用错的值")
    func wrappedResponseFailsLoudly() async throws {
        let api = StubAPIClient()
        // 服务端若改成对象包装，这里必须失败。
        stubTrigger(api: api, returning: #"{"pipelineRunId":33}"#)

        let error = await #expect(throws: APIError.self) {
            _ = try await makeService(api: api).runPipeline(branch: "test", environment: .test)
        }

        guard case .decodingFailed(let reason) = error else {
            Issue.record("期望 .decodingFailed，实际是 \(String(describing: error))")
            return
        }
        #expect(reason.contains("Int"), "解析失败信息没有指出期望的类型：\(reason)")
    }

    @Test("触发返回非正数时判为无效，不再往下走")
    func nonPositiveRunIDIsRejected() async throws {
        let api = StubAPIClient()
        stubTrigger(api: api, returning: "0")

        await #expect(throws: FlowServiceError.invalidPipelineRunID(0)) {
            _ = try await makeService(api: api).runPipeline(branch: "test", environment: .test)
        }
    }

    @Test("触发返回 404 时错误原样抛出，不掩盖成别的失败")
    func trigger404SurfacesAsNotFound() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .failure(.notFound))

        await #expect(throws: APIError.notFound) {
            _ = try await makeService(api: api).runPipeline(branch: "test", environment: .test)
        }
    }

    // MARK: - 轮询状态

    @Test("轮询走 /runs/{pipelineRunId}，且用的是本次的 ID")
    func statusPollingUsesRunsPrefixWithTheActualID() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs/33", .success(Self.runPayload(id: 33, status: "RUNNING")))

        let run = try await makeService(api: api)
            .fetchRunStatus(pipelineId: Self.pipeline, pipelineRunId: 33)

        #expect(run.runStatus == .running)
        // 原文照原样保留下来 —— 界面上的「服务端返回 status：RUNNING」就是它。
        #expect(run.status == "RUNNING")
        #expect(run.pipelineRunId == 33)
        #expect(api.requestedRoutes == ["GET \(Self.base)/runs/33"])
    }

    @Test("最后一次运行的 SUCCESS 状态被识别为终态成功")
    func successStatusIsRecognized() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs/34", .success(Self.runPayload(id: 34, status: "SUCCESS")))

        let run = try await makeService(api: api)
            .fetchRunStatus(pipelineId: Self.pipeline, pipelineRunId: 34)

        #expect(run.runStatus == .succeeded)
        #expect(run.runStatus.isTerminal)
    }

    // MARK: - Job / Step / Build 定位

    /// 运行详情：含一个「编译并构建上传」Job 与一个无关 Job。
    private static let runDetail = """
    {
      "pipelineRunId": 35,
      "pipelineId": 5000001,
      "status": "SUCCESS",
      "startTime": 1790046747000,
      "triggerMode": 4,
      "stages": [
        { "stageInfo": { "jobs": [
            { "id": 111111111, "name": "代码检查" },
            { "id": 6000001, "name": "编译并构建上传" }
        ] } }
      ]
    }
    """

    /// 运行状态查询用的完整响应 —— **按真实接口的字段给**。
    ///
    /// ⚠️ 这里刻意**不写 `startTime`**：运行详情接口没有这个字段，
    /// 它给的是 `createTime` / `updateTime`。曾经因为轮询复用了一个
    /// "必须有 startTime" 的模型，导致打包刚触发就报解析失败。
    /// 这个 fixture 就是那条回归的看门人，别为了"看着整齐"把 startTime 加回来。
    private static func runPayload(id: Int, status: String) -> String {
        """
        {
          "pipelineRunId": \(id),
          "pipelineId": 5000001,
          "status": "\(status)",
          "triggerMode": 4,
          "createTime": 1790046747000,
          "updateTime": 1790046749000,
          "pipelineConfigId": 3000001,
          "creatorAccountId": "",
          "modifierAccountId": "",
          "stages": []
        }
        """
    }

    @Test("轮询的响应里没有 startTime —— 缺这个字段不能让整个流程失败")
    func pollingToleratesMissingStartTime() async throws {
        let api = StubAPIClient()
        // 真实的 /runs/{id} 响应：只有 createTime / updateTime，没有 startTime。
        api.stub(
            path: "\(Self.base)/runs/35",
            .success(
                """
                {"pipelineRunId":35,"pipelineId":5000001,"status":"RUNNING",
                 "triggerMode":4,"createTime":1790046747000,"updateTime":1790046749000,
                 "creatorAccountId":"","modifierAccountId":"","stages":[]}
                """
            )
        )

        let run = try await makeService(api: api)
            .fetchRunStatus(pipelineId: Self.pipeline, pipelineRunId: 35)

        #expect(run.runStatus == .running)
        #expect(run.status == "RUNNING")
        // 详情接口本来就没有 startTime，缺这个字段时是 nil 而不是解码失败。
        #expect(run.startTime == nil)
    }

    /// 结果页那行「构建时间」的来源。
    ///
    /// ⚠️ 这条用例是**回归看门人**：`fetchRunHead` 曾经只读 `detail.startTime`，
    /// 而 `/runs/{id}` 这个端点实测**根本没有** `startTime`（只有 `createTime`），
    /// 于是恒为 `nil`、界面上永远显示占位符 —— 而历史列表里同一时刻却显示得好好的。
    /// 下面这份 fixture 就是真实响应里与时间有关的那几个字段，一个不多一个不少。
    @Test("运行详情只给 createTime 时，构建时间照样取得到")
    func runHeadFallsBackToCreateTime() async throws {
        let api = StubAPIClient()
        // 真实形状：没有 startTime，只有 createTime / updateTime。
        api.stub(
            path: "\(Self.base)/runs/35",
            .success(
                """
                {"pipelineRunId":35,"pipelineId":5000001,"status":"SUCCESS",
                 "triggerMode":4,"createTime":1790046747000,"updateTime":1790046749000,
                 "creatorAccountId":"","modifierAccountId":"","stages":[]}
                """
            )
        )

        let head = try await makeService(api: api)
            .fetchRunHead(pipelineId: Self.pipeline, pipelineRunId: 35)

        // 取的是服务端原文的毫秒时间戳，不是本地当前时间 ——
        // 编一个"现在"的表现是三天前那条记录显示成刚刚构建的，且看不出是编的。
        #expect(head.createdAt == 1790046747000)
    }

    @Test("运行详情里两个时间字段都没有时仍是 nil，不拿本地时间兜底")
    func runHeadStaysNilWhenNoTimeFieldAtAll() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)/runs/35",
            .success(#"{"pipelineRunId":35,"pipelineId":5000001,"status":"RUNNING"}"#)
        )

        let head = try await makeService(api: api)
            .fetchRunHead(pipelineId: Self.pipeline, pipelineRunId: 35)

        #expect(head.createdAt == nil)
    }

    @Test("CANCELED 是终态，且不等于失败")
    func canceledIsTerminalAndNotFailure() {
        let status = PipelineRunStatus(rawStatus: "CANCELED")

        #expect(status == .canceled)
        #expect(status.isTerminal)
        #expect(status != .failed)
    }

    @Test("轮询到 CANCELED 会停下来，而不是一直等到超时")
    func canceledStopsPolling() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs/36", .success(Self.runPayload(id: 36, status: "CANCELED")))

        let run = try await makeService(api: api)
            .fetchRunStatus(pipelineId: Self.pipeline, pipelineRunId: 36)

        #expect(run.runStatus == .canceled)
        #expect(run.runStatus.isTerminal)
        // 只查了一次 —— 终态立刻返回，没有按 2 秒间隔继续轮询。
        #expect(api.requestedRoutes == ["GET \(Self.base)/runs/36"])
    }

    @Test("触发方式按 triggerMode 原文归类，4 是 API 触发")
    func triggerModeIsClassifiedFromRawValue() {
        // 本项目自己触发出来的运行，实测 triggerMode 就是 4。
        #expect(TriggerMode(rawValue: 4) == .api)
        #expect(TriggerMode(rawValue: 1) == .manual)
        // 认不出来的取值保留原文，不猜。
        #expect(TriggerMode(rawValue: 9) == .other(9))
        #expect(TriggerMode(rawValue: 9).displayName.contains("9"))
    }

    /// 步骤列表（**运行中**的形态）：`stepName` 还是裸名字，没有耗时后缀。
    private static let stepsWhileRunning = """
    [
      {
        "buildId": 7000001,
        "jobId": 6000001,
        "actionCode": "EXECUTION_COMPONENT_BUILD",
        "actionName": "构建",
        "buildProcessNodes": [
          { "nodeName": "克隆代码", "stepName": "克隆代码", "status": "success", "stepIndex": 2 },
          { "nodeName": "执行命令", "stepName": "执行命令", "status": "running", "stepIndex": 7 },
          { "nodeName": "缓存上传", "stepName": "缓存上传", "status": "ready", "stepIndex": 8 }
        ]
      }
    ]
    """

    /// 步骤列表（**已结束**的形态）—— 真实响应原文，不是编的。
    ///
    /// ⚠️ 服务端在步骤跑完后会把 `stepName` 与 `nodeName` **一起**改写成
    /// 「名字(耗时)」：运行中的 `执行命令` 结束后变成 `执行命令(267s)`。
    ///
    /// 这个 fixture 是那条线上故障的看门人：客户端是等终态才来取 steps 的，
    /// 所以它拿到的**永远**是带后缀的这一份。之前的 fixture 用的是运行中的形态，
    /// 于是"按名字精确相等匹配"这个 bug 一路绿灯通过了测试，
    /// 真机上却让整条打包流程以「未找到 stepName 为『执行命令』的步骤」收场。
    ///
    /// 别为了"看着整齐"把后缀去掉。
    private static let stepsAtTerminal = """
    [
      {
        "buildId": 7000001,
        "jobId": 7000001,
        "actionCode": "EXECUTION_COMPONENT_BUILD",
        "actionName": "构建",
        "startTime": "2026-09-22 11:12:29.0",
        "buildProcessNodes": [
          { "nodeName": "申请运行环境(18s)", "stepName": "申请运行环境(18s)", "status": "success", "stepIndex": 0 },
          { "nodeName": "清理工作区(0s)", "stepName": "清理工作区(0s)", "status": "success", "stepIndex": 1 },
          { "nodeName": "克隆代码(6s)", "stepName": "克隆代码(6s)", "status": "success", "stepIndex": 2 },
          { "nodeName": "流水线缓存(30s)", "stepName": "流水线缓存(30s)", "status": "success", "stepIndex": 3 },
          { "nodeName": "执行命令(331s)", "stepName": "执行命令(331s)", "status": "success", "stepIndex": 4 },
          { "nodeName": "缓存上传(28s)", "stepName": "缓存上传(28s)", "status": "success", "stepIndex": 5 }
        ]
      }
    ]
    """

    @Test("从本次运行详情里按名字取 jobId，全程走 /runs 与 /pipelineRuns 两套前缀")
    func stepTargetIsResolvedFromRunDetail() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs/35", .success(Self.runDetail))
        api.stub(path: "\(Self.base)/pipelineRuns/35/jobs/6000001/steps", .success(Self.stepsAtTerminal))

        let service = makeService(api: api)
        let head = try await service.fetchRunHead(pipelineId: Self.pipeline, pipelineRunId: 35)
        #expect(head.status == "SUCCESS")
        #expect(head.createdAt == 1790046747000)
        #expect(head.jobID == 6000001)

        let target = try await service.buildStepTarget(
            pipelineId: Self.pipeline,
            pipelineRunId: 35,
            jobID: head.jobID
        )

        #expect(target.jobID == 6000001)
        #expect(target.buildID == 7000001)
        // 终态响应里步骤名带耗时后缀（`执行命令(331s)`），仍然要能按名字查到。
        #expect(target.stepIndex == 4)
        #expect(api.requestedRoutes == [
            "GET \(Self.base)/runs/35",
            "GET \(Self.base)/pipelineRuns/35/jobs/6000001/steps",
        ])
    }

    @Test("步骤跑完后名字多了耗时后缀，运行中的形态照样能定位到同一步骤")
    func durationSuffixDoesNotBreakStepLookup() async throws {
        let api = StubAPIClient()

        // 同一次运行、同一个步骤，只差服务端在终态追加的 `(耗时)`。
        for (payload, label) in [
            (Self.stepsWhileRunning, "运行中"),
            (Self.stepsAtTerminal, "已结束"),
        ] {
            api.stub(path: "\(Self.base)/runs/35", .success(Self.runDetail))
            api.stub(path: "\(Self.base)/pipelineRuns/35/jobs/6000001/steps", .success(payload))

            let service = makeService(api: api)
            let head = try await service.fetchRunHead(pipelineId: Self.pipeline, pipelineRunId: 35)
            let target = try await service.buildStepTarget(
                pipelineId: Self.pipeline,
                pipelineRunId: 35,
                jobID: head.jobID
            )

            // 两种形态拿到的是同一个 buildId，且都不是写死的 ——
            // 序号 7 与 4 分别来自各自的 fixture。
            #expect(target.buildID == 7000001, "\(label)形态下 buildId 没取到")
            #expect(
                target.stepIndex == (label == "运行中" ? 7 : 4),
                "\(label)形态下 stepIndex 不对：\(target.stepIndex)"
            )
        }
    }

    @Test("耗时后缀只在结尾才剥，名字里中间的括号不受影响")
    func suffixStrippingOnlyTouchesTheTrailingDuration() throws {
        let steps = try JSONDecoder().decode(
            [PipelineStep].self,
            from: Data(
                """
                [{"buildId":1,"jobId":1,"buildProcessNodes":[
                  {"nodeName":"打包(测试)(12s)","stepName":"打包(测试)(12s)","stepIndex":3}
                ]}]
                """.utf8
            )
        )
        let step = try #require(steps.first)

        // 结尾的 `(12s)` 剥掉，中间的 `(测试)` 留着。
        #expect(step.hasStep(named: "打包(测试)"))
        #expect(step.stepIndex(named: "打包(测试)") == 3)

        // 不能退化成前缀匹配 —— 否则「打包」也会命中，那是另一个步骤的名字。
        #expect(!step.hasStep(named: "打包"))
    }

    @Test("剥后缀只认「带时间单位的结尾括号」，别的一律不动")
    func baseNameStripsOnlyTimedSuffixes() {
        // 要剥的形态。
        #expect(BuildProcessNode.baseName("执行命令(331s)") == "执行命令")
        #expect(BuildProcessNode.baseName("申请运行环境(18s)") == "申请运行环境")
        #expect(BuildProcessNode.baseName("克隆代码(1m 30s)") == "克隆代码")
        #expect(BuildProcessNode.baseName("缓存上传(1h2m3s)") == "缓存上传")

        // 不该动的形态 —— 一个剥错就是把别的步骤名啃掉。
        #expect(BuildProcessNode.baseName("执行命令") == "执行命令")
        #expect(BuildProcessNode.baseName("打包(测试)") == "打包(测试)")
        // 纯数字括号不是耗时，是名字的一部分。
        #expect(BuildProcessNode.baseName("打包(2)") == "打包(2)")
        // 括号后面还有别的内容：不是结尾，不剥。
        #expect(BuildProcessNode.baseName("执行命令(331s) 重试") == "执行命令(331s) 重试")
        // 中间的括号本来就不该被看见，但确认一下正则没有跨段匹配。
        #expect(BuildProcessNode.baseName("打包(测试)(12s)") == "打包(测试)")
    }

    @Test("归一化之后是相等匹配，不是包含匹配")
    func matchingIsEqualityAfterNormalizationOnly() {
        let step = PipelineStep(
            buildId: 1,
            jobId: 1,
            actionCode: nil,
            actionName: nil,
            buildProcessNodes: [
                BuildProcessNode(nodeName: "执行命令2(5s)", stepName: "执行命令2(5s)", stepIndex: 9, status: nil)
            ]
        )

        // 「执行命令2」不能因为开头一样就被当成「执行命令」。
        #expect(!step.hasStep(named: FlowService.buildStepName))
        #expect(step.hasStep(named: "执行命令2"))
        #expect(step.stepIndex(named: "执行命令2") == 9)
    }

    @Test("没有 stepName 的节点靠 nodeName 兜底，同样会剥后缀")
    func nodeNameIsTheFallback() throws {
        let steps = try JSONDecoder().decode(
            [PipelineStep].self,
            from: Data(
                """
                [{"buildId":7,"jobId":7,"buildProcessNodes":[
                  {"nodeName":"执行命令(331s)","stepIndex":4}
                ]}]
                """.utf8
            )
        )
        let step = try #require(steps.first)

        #expect(step.hasStep(named: FlowService.buildStepName))
        #expect(step.stepIndex(named: FlowService.buildStepName) == 4)
    }

    @Test("运行详情里没有目标 Job 时报明确错误，不退化成取第一个 Job")
    func missingJobNameIsReported() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)/runs/36",
            .success(
                """
                {"pipelineRunId":36,"pipelineId":5000001,"status":"SUCCESS",
                 "stages":[{"stageInfo":{"jobs":[{"id":1,"name":"代码检查"}]}}]}
                """
            )
        )

        let service = makeService(api: api)
        // 头部这一步**不报错**：没有目标 Job 的运行照常返回，`jobID` 为 `nil`。
        // 判"找不到就失败"落在下一步，因为失败 / 取消的运行本来就走不到那里。
        let head = try await service.fetchRunHead(pipelineId: Self.pipeline, pipelineRunId: 36)
        #expect(head.jobID == nil)

        let error = await #expect(throws: FlowServiceError.self) {
            _ = try await service.buildStepTarget(
                pipelineId: Self.pipeline,
                pipelineRunId: 36,
                jobID: head.jobID
            )
        }

        guard case .missingIdentifier(let detail) = error else {
            Issue.record("期望 .missingIdentifier，实际是 \(String(describing: error))")
            return
        }
        #expect(detail.contains(FlowService.buildJobName))
    }

    @Test("步骤列表里没有「执行命令」时报明确错误，并带上本次响应里真实的步骤名")
    func missingStepNameIsReported() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs/35", .success(Self.runDetail))
        api.stub(
            path: "\(Self.base)/pipelineRuns/35/jobs/6000001/steps",
            .success(
                """
                [{"buildId":1,"jobId":6000001,"buildProcessNodes":[
                  {"nodeName":"准备(1s)","stepName":"准备(1s)","stepIndex":0},
                  {"nodeName":"打包(2s)","stepName":"打包(2s)","stepIndex":1}
                ]}]
                """
            )
        )

        let error = await #expect(throws: FlowServiceError.self) {
            _ = try await makeService(api: api).buildStepTarget(
                pipelineId: Self.pipeline,
                pipelineRunId: 35,
                jobID: 6000001
            )
        }

        guard case .missingIdentifier(let detail) = error else {
            Issue.record("期望 .missingIdentifier，实际是 \(String(describing: error))")
            return
        }
        #expect(detail.contains(FlowService.buildStepName))
        // 下一次同类故障的止损：报错文案里要能直接看到服务端给的实际节点名，
        // 而不是只有"没找到"三个字，逼得再去远程抓一次响应。
        #expect(detail.contains("准备(1s)"), "报错没带上实际节点名：\(detail)")
        #expect(detail.contains("打包(2s)"), "报错没带上实际节点名：\(detail)")
    }

    @Test("步骤列表里一个节点都没有时，报错说明这一点而不是拼出空列表")
    func missingStepNameWithNoNodesIsReported() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs/35", .success(Self.runDetail))
        api.stub(
            path: "\(Self.base)/pipelineRuns/35/jobs/6000001/steps",
            .success(#"[{"buildId":1,"jobId":6000001,"buildProcessNodes":[]}]"#)
        )

        let error = await #expect(throws: FlowServiceError.self) {
            _ = try await makeService(api: api).buildStepTarget(
                pipelineId: Self.pipeline,
                pipelineRunId: 35,
                jobID: 6000001
            )
        }

        guard case .missingIdentifier(let detail) = error else {
            Issue.record("期望 .missingIdentifier，实际是 \(String(describing: error))")
            return
        }
        #expect(detail.contains("没有任何步骤节点"), "报错文案不对：\(detail)")
    }

    // MARK: - 日志

    @Test("日志请求带上 stepIndex / buildId，并按整段读取")
    func logRequestCarriesIdentifiersAndWindow() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)/pipelineRuns/35/jobs/6000001/step/log",
            .success(#"{"last":-1,"logs":"上传完成->https://apk.example.com/a/x.apk","more":false}"#)
        )

        let target = StepTarget(jobID: 6000001, stepIndex: 7, buildID: 7000001)
        let logs = try await makeService(api: api)
            .fetchStepLog(pipelineId: Self.pipeline, pipelineRunId: 35, target: target)

        #expect(logs == "上传完成->https://apk.example.com/a/x.apk")
        #expect(api.requestedRoutes == [
            "GET \(Self.base)/pipelineRuns/35/jobs/6000001/step/log"
        ])
        #expect(api.requestedQuery == [
            "stepIndex": "7",
            "offset": "0",
            "limit": "10000",
            "buildId": "7000001",
        ])
    }

    @Test("`last` 为 -1 不影响 logs 解析")
    func negativeLastCursorIsFine() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)/pipelineRuns/35/jobs/1/step/log",
            .success(#"{"last":-1,"logs":"正文","more":false}"#)
        )

        let logs = try await makeService(api: api).fetchStepLog(
            pipelineId: Self.pipeline,
            pipelineRunId: 35,
            target: StepTarget(jobID: 1, stepIndex: 0, buildID: 1)
        )

        #expect(logs == "正文")
    }

    // MARK: - 具体 Run 的 pipelineId 参与请求路径

    /// 传进去的 `pipelineId` 必须**原样出现在 HTTP 路径里**。
    ///
    /// 这是整个 Phase 5-B 的存在理由：`pipelineId` 是"这次运行属于哪条流水线"的
    /// 唯一凭据，而它写错了**不会编译失败、也不会让服务端拒绝** —— 只会静默地
    /// 问到另一条流水线上，把那条流水线里 ID 恰好相同的运行当成这一次的结果。
    /// 界面上看起来一切正常。
    ///
    /// 因此这里用两条**同号但是 ID 不同**的流水线（`111` / `222`），
    /// 对每个方法都传入 `222`，再把整条路径钉死成含 `222` 的那一条。
    /// 若实现里把 `pipelineId` 换成了"按 environment 反查"（或干脆丢掉），
    /// 路径就会变成 `111` 的那一份，在这里红。
    ///
    /// 覆盖全部四个"针对具体 Run"的接口 —— 少覆盖一个，那一个就可能是漏洞。
    @Test("具体 Run 的查询把 pipelineId 拼进路径：传入 222，路径里就得有 222")
    func concreteRunQueriesCarryPipelineIdIntoThePath() async throws {
        let asked = "222"
        let base = "/oapi/v1/flow/organizations/\(Self.org)/pipelines/\(asked)"
        let api = StubAPIClient()

        api.stub(path: "\(base)/runs/35", .success(Self.runDetail))
        api.stub(
            path: "\(base)/pipelineRuns/35/jobs/6000001/steps",
            .success(Self.stepsAtTerminal)
        )
        api.stub(
            path: "\(base)/pipelineRuns/35/jobs/6000001/step/log",
            .success(#"{"last":-1,"logs":"正文","more":false}"#)
        )

        // `Self.config` 里 222 属于 release —— 刻意用与 `asked` 不同的那个环境
        // 混进来，说明路径里的号来自参数，而不是"配置里第一个环境"。
        let service = makeService(api: api)

        _ = try await service.fetchRunStatus(pipelineId: asked, pipelineRunId: 35)
        let head = try await service.fetchRunHead(pipelineId: asked, pipelineRunId: 35)
        _ = try await service.buildStepTarget(
            pipelineId: asked,
            pipelineRunId: 35,
            jobID: head.jobID
        )
        _ = try await service.fetchStepLog(
            pipelineId: asked,
            pipelineRunId: 35,
            target: StepTarget(jobID: 6000001, stepIndex: 4, buildID: 7000001)
        )

        let routes = api.requestedRoutes
        #expect(routes.count == 4, "四个方法应当各发一次请求，实际 \(routes)")
        for route in routes {
            #expect(
                route.contains("/pipelines/\(asked)/"),
                "请求打到了别的流水线上：\(route)"
            )
        }
    }

    // MARK: - 环境与配置

    /// 流水线详情响应 —— **按真实接口的字段给**。
    ///
    /// ⚠️ `version` 在 `pipelineConfig` 里面，**根节点没有这个字段**。
    /// 曾经按"根节点有 version"建模，界面就长期挂着一行
    /// `PipelineInfo 缺少字段 version（在 响应根节点）`。
    /// 这个 fixture 就是那条回归的看门人，别把 version 挪到根节点去。
    ///
    /// ⚠️ `sources[].data.repo` 也**必须留着**：它是触发请求体里 `runningBranchs`
    /// 的键，只能从这里取。少了它，`runPipeline` 会在发请求之前就抛
    /// `missingIdentifier` —— 这不是"fixture 精简了"，而是一条成功路径被判死了。
    /// 顺带注意 `data` 里那一堆 `serviceConnectionId` / `credentialId` / `commit`
    /// 是**故意留着**的：它们在真实响应里就有，而客户端一个都不建模。
    private static let pipelineInfoPayload = """
    {"name":"Example-App-Android","id":5000001,"pipelineConfigId":3000001,
     "pipelineConfig":{
       "version":35,
       "sources":[
         {"type":"codeup","sign":"example-sign","name":"ExampleApp_57vT",
          "label":"example-group/ExampleApp",
          "data":{"branch":"test","repo":"\(repoURL)","serviceConnectionId":123,
                  "credentialId":456,"commit":"abc1234"}}
       ]}}
    """

    /// 触发体的键。**不是**写死在生产代码里的常量 —— 生产代码只从流水线详情读它。
    private static let repoURL = "https://codeup.aliyun.com/\(org)/example-group/ExampleApp.git"

    @Test("流水线版本在 pipelineConfig 里，不在根节点")
    func versionComesFromPipelineConfig() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)", .success(Self.pipelineInfoPayload))

        let info = try await makeService(api: api).fetchPipelineInfo(environment: .test)

        #expect(info.name == "Example-App-Android")
        #expect(info.version == 35)
    }

    @Test("仓库地址从 pipelineConfig.sources[].data.repo 读出来，不是常量")
    func repoURLComesFromPipelineConfig() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)", .success(Self.pipelineInfoPayload))

        let info = try await makeService(api: api).fetchPipelineInfo(environment: .test)

        #expect(info.repoURL == Self.repoURL)
    }

    @Test("没有代码源时仓库地址为 nil，而不是拼出一个空串")
    func missingSourcesYieldsNoRepoURL() async throws {
        let api = StubAPIClient()
        // 详情能拿到、但没有 sources：展示照常，只是发不出带参数的触发请求。
        api.stub(
            path: "\(Self.base)",
            .success(#"{"name":"Example-App-Android","id":5000001,"pipelineConfigId":1,"pipelineConfig":{"version":35}}"#)
        )

        let info = try await makeService(api: api).fetchPipelineInfo(environment: .test)

        #expect(info.version == 35)
        #expect(info.repoURL == nil)
    }

    @Test("pipelineConfig 整个缺失时版本为 nil，而不是让页面加载失败")
    func missingPipelineConfigIsNotAFailure() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)",
            .success(#"{"name":"Example-App-Android","id":5000001,"pipelineConfigId":3000001}"#)
        )

        let info = try await makeService(api: api).fetchPipelineInfo(environment: .test)

        #expect(info.id == 5000001)
        #expect(info.version == nil)
    }

    @Test("按环境取各自的流水线 ID")
    func environmentSelectsPipelineID() async throws {
        let api = StubAPIClient()
        api.stubEverything(.success(Self.pipelineInfoPayload))

        let config = BuildConfig(
            yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
            organizationId: Self.org,
            pipelines: ["test": "111", "release": "222"]
        )
        let service = FlowService(api: api, config: { config })

        _ = try await service.fetchPipelineInfo(environment: .test)
        _ = try await service.fetchPipelineInfo(environment: .release)

        #expect(api.requestedRoutes == [
            "GET /oapi/v1/flow/organizations/\(Self.org)/pipelines/111",
            "GET /oapi/v1/flow/organizations/\(Self.org)/pipelines/222",
        ])
    }

    @Test("环境没有配流水线 ID 时不发请求，直接报配置缺失")
    func missingEnvironmentPipelineIDIsReported() async throws {
        let api = StubAPIClient()
        api.stubEverything(.success("{}"))
        let config = BuildConfig(
            yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
            organizationId: Self.org,
            pipelines: ["test": "111"]
        )

        await #expect(throws: FlowServiceError.configurationMissing("pipelines.release")) {
            _ = try await FlowService(api: api, config: { config })
                .fetchPipelineRuns(environment: .release)
        }
        #expect(api.requestedPaths.isEmpty, "配置不全时不应发出请求")
    }

    @Test("历史记录接口返回裸数组，整体解码")
    func historyIsABareArray() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)/runs",
            .success(
                """
                [{"pipelineRunId":30,"pipelineId":5000001,"status":"SUCCESS",
                  "startTime":1790046747000,"endTime":1790047099000,
                  "triggerMode":4,"creatorAccountId":null}]
                """
            )
        )

        let runs = try await makeService(api: api).fetchPipelineRuns(environment: .test)

        #expect(runs.map(\.pipelineRunId) == [30])
        #expect(runs.first?.runStatus == .succeeded)
        // 没有触发者时是 nil，界面显示占位符而不是空字符串。
        #expect(runs.first?.creatorID == nil)
    }

    @Test("历史记录里的 creatorAccountId 映射到 creatorID —— 改名不能把解码改坏")
    func creatorAccountIDIsMappedToCreatorID() async throws {
        let api = StubAPIClient()
        api.stub(
            path: "\(Self.base)/runs",
            .success(
                """
                [{"pipelineRunId":30,"pipelineId":5000001,"status":"SUCCESS",
                  "startTime":1790046747000,"endTime":1790047099000,
                  "triggerMode":4,"creatorAccountId":"example-account-1"},
                 {"pipelineRunId":29,"pipelineId":5000001,"status":"FAIL",
                  "startTime":1790046000000,"endTime":1790046100000,
                  "triggerMode":1,"creatorAccountId":"example-account-2"}]
                """
            )
        )

        let runs = try await makeService(api: api).fetchPipelineRuns(environment: .test)

        #expect(runs.map(\.creatorID) == ["example-account-1", "example-account-2"])
        #expect(runs.map(\.trigger) == [.api, .manual])
        #expect(runs.map(\.runStatus) == [.succeeded, .failed])
    }
}
