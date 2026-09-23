import Foundation
import Testing

@testable import AndroidBuildClient

/// `BuildService` 的测试 —— 「一次运行的构建结果」这唯一入口。
///
/// 这里断言的核心**不是**路径字形（那是 `FlowServiceTests` 的事），而是
/// **这条链路的走向**：
/// ```
/// 运行详情 → 该不该继续往下找产物 → 步骤定位 → 日志 → 产物
/// ```
/// 尤其是那条最危险的规则：**只有成功终态才去找产物**。
/// 认不出的状态值如果继续往下读日志，日志里恰好残留着上一次运行的标记，
/// 界面上就会出现一个假的 APK 地址 —— 而它对应的构建根本没成功。
///
/// 不碰网络：`StubAPIClient` 按路径回放应答。
@Suite("BuildService")
struct BuildServiceTests {

    private static let org = "example-org-id"
    private static let pipeline = "5000001"
    private static let base = "/oapi/v1/flow/organizations/\(org)/pipelines/\(pipeline)"

    private static let config = BuildConfig(
        yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
        organizationId: org,
        pipelines: ["test": pipeline, "release": pipeline]
    )

    /// 「编译并构建上传」这个 Job 的真实 ID。
    private static let jobID = 6000001
    private static let buildID = 7000001
    /// 本次运行的 ID。
    private static let runID = 41

    /// 毫秒级的重试节奏 —— 生产是 3 次 × 间隔 2 秒，用例不该真等 4 秒。
    private static let fastRetry = AppConfiguration.ResultParsing(
        maxAttempts: 3,
        delay: .milliseconds(10)
    )

    private func makeService(api: StubAPIClient) -> BuildService {
        BuildService(
            flowService: FlowService(api: api, config: { Self.config }),
            parser: BuildLogParser(),
            resultParsing: Self.fastRetry
        )
    }

    // MARK: - 接口路径

    private static func runPath(_ id: Int = runID) -> String { "\(base)/runs/\(id)" }

    private static func stepsPath(_ id: Int = runID) -> String {
        "\(base)/pipelineRuns/\(id)/jobs/\(jobID)/steps"
    }

    private static func logPath(_ id: Int = runID) -> String {
        "\(base)/pipelineRuns/\(id)/jobs/\(jobID)/step/log"
    }

    // MARK: - 应答

    /// 运行详情。`startTime` / `createTime` 里先有的那个就是界面上的「构建时间」，
    /// **来自服务端**。
    ///
    /// ⚠️ 真实接口（`GET …/runs/{id}`）给的是 **`createTime`**，**没有** `startTime`；
    /// 历史记录接口（`GET …/runs`）才是给 `startTime` 的那个。两条链路同一个事实
    /// 两个名字，所以下面两个字段都能单独发出去、也都能单独省掉。
    ///
    /// `stages` 里那三个 Job 是刻意留的：`编译并构建上传` 夹在中间，
    /// 防止实现退化成"取第一个 Job"。
    private static func runDetail(
        status: String,
        id: Int = runID,
        startTime: Int64? = 1_790_046_747_000,
        createTime: Int64? = nil
    ) -> String {
        var times: [String] = []
        if let startTime { times.append("\"startTime\": \(startTime),") }
        if let createTime { times.append("\"createTime\": \(createTime),") }
        return """
        {
          "pipelineRunId": \(id),
          "pipelineId": 5000001,
          "status": "\(status)",
          \(times.joined(separator: "\n  "))
          "triggerMode": 4,
          "stages": [
            { "stageInfo": { "jobs": [
                { "id": 111111111, "name": "代码检查" },
                { "id": \(jobID), "name": "编译并构建上传" },
                { "id": 999999999, "name": "通知" }
            ] } }
          ]
        }
        """
    }

    /// 终态步骤列表：名字带服务端追加的耗时后缀（真实原文）。
    private static let stepsPayload = """
    [
      {
        "buildId": \(buildID),
        "jobId": \(jobID),
        "buildProcessNodes": [
          { "nodeName": "克隆代码(6s)", "stepName": "克隆代码(6s)", "stepIndex": 2 },
          { "nodeName": "执行命令(331s)", "stepName": "执行命令(331s)", "stepIndex": 4 }
        ]
      }
    ]
    """

    private static func logPayload(_ logs: String) -> String {
        #"{"last":-1,"logs":"\#(logs)","more":false}"#
    }

    /// 带两个产物标记的日志 —— 地址是真实形状，不含任何敏感信息。
    private static let logWithArtifacts = logPayload(
        #"上传完成->https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk\n"#
            + #"二维码地址->https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png"#
    )

    /// 跑完了，但日志里一个产物标记都没有。
    private static let logWithoutArtifacts = logPayload("BUILD SUCCESSFUL in 4m 12s")

    /// 把「详情 + 步骤 + 日志」三段都挂上 —— 成功路径的完整应答。
    private static func stubSuccess(
        _ api: StubAPIClient,
        status: String = "SUCCESS",
        log: String = logWithArtifacts
    ) {
        api.stub(path: stepsPath(), .success(stepsPayload))
        api.stub(path: logPath(), .success(log))
        api.stub(path: runPath(), .success(runDetail(status: status)))
    }

    // MARK: - 成功路径

    @Test("成功的一次运行：状态、开始时间与两个产物地址都取回来")
    func successfulRunReturnsArtifacts() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        // 服务端原文照搬，不做措辞替换 —— 界面要能核对服务端到底回了什么。
        #expect(result.status == "SUCCESS")
        #expect(result.runStatus == .succeeded)
        #expect(result.isSuccessful)
        #expect(result.createdAt == 1_790_046_747_000)
        #expect(
            result.artifacts.apkURL?.absoluteString
                == "https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk"
        )
        #expect(
            result.artifacts.qrCodeURL?.absoluteString
                == "https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png"
        )

        // 三次读，一次不多：详情（状态 / 开始时间 / jobId）**只打一次**，
        // 不再为了单独取 jobId 把同一个接口重打一遍。
        #expect(api.requestedRoutes == [
            "GET \(Self.runPath())",
            "GET \(Self.stepsPath())",
            "GET \(Self.logPath())",
        ])
    }

    @Test("pipelineRunId 本身就是唯一标识，不另外生成")
    func identityIsTheRunID() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.pipelineRunId == Self.runID)
        #expect(result.id == Self.runID)
    }

    @Test("步骤定位用的是接口给的 jobId / buildId / stepIndex，一个都不是写死的")
    func logRequestCarriesResolvedIdentifiers() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)

        _ = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        // 路径里三段都是动态取得的值（jobId 来自 stages，runId 来自入参）。
        #expect(api.requestedPaths.contains(Self.stepsPath()))
        #expect(api.requestedPaths.contains(Self.logPath()))

        let query = api.requestedQuery(forPath: Self.logPath())
        #expect(query["buildId"] == "\(Self.buildID)")
        // `执行命令(331s)` 带耗时后缀，仍然要定位到它自己的序号 4，而不是写死 4。
        #expect(query["stepIndex"] == "4")
        // 整段读取：不计算"最后 1000 行"。
        #expect(query["offset"] == "0")
        #expect(query["limit"] == "10000")
    }

    // MARK: - 非成功终态：绝不往下找产物

    @Test("失败的运行：只打一次详情，不去读步骤与日志，产物为空")
    func failedRunDoesNotLookForArtifacts() async throws {
        let api = StubAPIClient()
        // 刻意**不** stub steps / log：真去请求的话会走到错误分支而暴露出来。
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "FAIL")))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.status == "FAIL")
        #expect(result.runStatus == .failed)
        #expect(!result.isSuccessful)
        #expect(result.artifacts.isEmpty)
        #expect(api.requestedRoutes == ["GET \(Self.runPath())"])
    }

    @Test("被取消的运行归到 .canceled，不做「非成功即失败」的二值简化")
    func canceledRunUsesItsOwnStatus() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "CANCELED")))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.runStatus == .canceled)
        #expect(result.runStatus != .failed, "取消不是失败，界面上是两种不同的收场")
        #expect(!result.isSuccessful)
        #expect(result.artifacts.isEmpty)
    }

    @Test("认不出的状态值绝不被当成成功：不读日志，产物为空")
    func unknownStatusIsNeverTreatedAsSuccess() async throws {
        let api = StubAPIClient()
        // 服务端将来新增的状态值。日志**故意**是可解析出产物的那一份 ——
        // 这就是真机上会踩的坑：上一次运行的标记还留在同一个步骤上，
        // 只要实现"状态不认识也照读日志"，界面上就会出现一个属于别人的 APK 地址。
        api.stub(path: Self.stepsPath(), .success(Self.stepsPayload))
        api.stub(path: Self.logPath(), .success(Self.logWithArtifacts))
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "QUEUE_PAUSED")))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.runStatus == .unknown("QUEUE_PAUSED"))
        #expect(!result.isSuccessful, "认不出 ≠ 成功")
        #expect(result.artifacts.apkURL == nil, "日志里那个地址不是这次运行的产物")
        #expect(result.artifacts.isEmpty)
        // 关键断言：一次都没有去读步骤与日志。
        #expect(api.requestedRoutes == ["GET \(Self.runPath())"])
    }

    @Test("运行还在跑时同样不展示产物 —— 那还没到有结果的时刻")
    func runningRunHasNoArtifacts() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "RUNNING")))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.runStatus == .running)
        #expect(!result.isSuccessful)
        #expect(result.artifacts.isEmpty)
    }

    // MARK: - 日志刷盘与重试

    @Test("状态已成功但日志还差最后一次刷盘：重试后拿到产物")
    func artifactsAreRetriedWhenTheLogIsNotFlushedYet() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.stepsPath(), .success(Self.stepsPayload))
        api.stubSequence(path: Self.logPath(), [
            .success(Self.logWithoutArtifacts),
            .success(Self.logWithArtifacts),
        ])
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "SUCCESS")))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.artifacts.apkURL != nil)
        // 第一次没读到就再读一次，而不是一次没解析到就宣告"没有产物"。
        #expect(api.requestedQueryValues(forPath: Self.logPath()).count == 2)
    }

    @Test("日志里始终没有标记时，重试次数有限，且仍然算成功")
    func missingArtifactsStopAfterFiniteRetriesAndStaySuccessful() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.stepsPath(), .success(Self.stepsPayload))
        api.stub(path: Self.logPath(), .success(Self.logWithoutArtifacts))
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "SUCCESS")))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        // ⚠️ 服务端原文确实是 SUCCESS，只是日志里没有产物标记。
        // 判成失败会误导用户去重跑一次**已经跑成功**的构建。
        #expect(result.status == "SUCCESS")
        #expect(result.isSuccessful)
        #expect(result.artifacts.isEmpty)

        // 重试必须有限：标记真的不存在时，无限重试只会让界面永远转圈。
        #expect(api.requestedQueryValues(forPath: Self.logPath()).count == Self.fastRetry.maxAttempts)
    }

    @Test("第一次就读到产物时不再重试")
    func noRetryWhenArtifactsAreAlreadyThere() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)

        _ = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(api.requestedQueryValues(forPath: Self.logPath()).count == 1)
    }

    // MARK: - 服务端没给的字段

    @Test("接口没给 startTime 时是 nil，不用本地当前时间兜底")
    func missingStartTimeStaysNil() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)
        api.stub(path: Self.runPath(), .success(Self.runDetail(status: "SUCCESS", startTime: nil)))

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        // 兜底成"现在"的表现是：历史里一条三天前的记录显示成刚刚构建的，
        // 而且看不出是编造的。宁可空着。
        #expect(result.createdAt == nil)
        // 时间缺失不影响产物 —— 两者来自不同的字段，不该互相带累。
        #expect(result.artifacts.apkURL != nil)
    }

    /// 结果页那行「构建时间」。
    ///
    /// ⚠️ 这条用例是**回归看门人**：真实接口（`GET …/runs/{id}`）给的是
    /// `createTime`，**没有** `startTime`。实现曾经只读 `startTime`，
    /// 于是在真机上恒为 `nil`、界面上永远是一个占位符 ——
    /// 而历史列表里同一时刻却显示得好好的，看起来像是结果页自己坏了。
    @Test("运行详情只给 createTime 时，构建时间照样取得到")
    func createTimeIsUsedWhenStartTimeIsAbsent() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)
        api.stub(
            path: Self.runPath(),
            .success(Self.runDetail(status: "SUCCESS", startTime: nil, createTime: 1_790_046_747_000))
        )

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        // 毫秒时间戳原样取回，不是本地当前时间。
        #expect(result.createdAt == 1_790_046_747_000)
    }

    @Test("两个时间字段都在时以 startTime 为准，与历史列表取的是同一个值")
    func startTimeWinsOverCreateTime() async throws {
        let api = StubAPIClient()
        Self.stubSuccess(api)
        api.stub(
            path: Self.runPath(),
            .success(
                Self.runDetail(
                    status: "SUCCESS",
                    startTime: 1_790_046_747_000,
                    createTime: 1_790_046_700_000
                )
            )
        )

        let result = try await makeService(api: api).fetchBuildResult(
            pipelineRunId: Self.runID,
            pipelineId: Self.pipeline
        )

        #expect(result.createdAt == 1_790_046_747_000)
    }

    @Test("运行详情里没有目标 Job 时，报错说明找的是哪个 Job 名")
    func missingBuildJobIsReported() async throws {
        let api = StubAPIClient()
        api.stub(
            path: Self.runPath(),
            .success(
                """
                {"pipelineRunId":\(Self.runID),"pipelineId":5000001,"status":"SUCCESS",
                 "stages":[{"stageInfo":{"jobs":[{"id":1,"name":"代码检查"}]}}]}
                """
            )
        )

        let error = await #expect(throws: FlowServiceError.self) {
            _ = try await makeService(api: api).fetchBuildResult(
                pipelineRunId: Self.runID,
                pipelineId: Self.pipeline
            )
        }

        guard case .missingIdentifier(let detail) = error else {
            Issue.record("期望 .missingIdentifier，实际是 \(String(describing: error))")
            return
        }
        #expect(detail.contains(FlowService.buildJobName))
    }
}
