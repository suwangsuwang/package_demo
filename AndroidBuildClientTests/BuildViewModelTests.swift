import Foundation
import Testing

@testable import AndroidBuildClient

/// 打包页状态机与"页面切走再切回来"的测试。
///
/// 这里的重点是**状态不随页面消失**：`BuildViewModel` 现在挂在 `AppModel` 上，
/// 比 `BuildView` 活得久。用户从打包页切到「Yunxiao 配置」再切回来时，
/// 正在轮询的任务必须还在跑、已经拿到的结果必须还在。
///
/// 测的是 `BuildViewModel` 这一层（持有者换了位置，行为必须不变）；
/// "View 用 `@State` 还是用 `AppModel` 上的实例"属于 SwiftUI 装配，
/// 不是这一层能断言的，因此由 `AppModel` 持有这个事实本身在代码里用注释钉住。
@Suite("BuildViewModel")
@MainActor
struct BuildViewModelTests {

    private static let org = "example-org-id"
    private static let pipeline = "5000001"
    private static let base = "/oapi/v1/flow/organizations/\(org)/pipelines/\(pipeline)"

    private static let config = BuildConfig(
        yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
        organizationId: org,
        pipelines: ["test": pipeline, "release": pipeline]
    )

    /// 一条**与生产配置不同的**流水线号，专门用来验"身份跟着流水线走、不跟着环境走"。
    ///
    /// ⚠️ 生产配置里 `test` 与 `release` 指向同一条流水线，于是
    /// 「本次运行属于哪条流水线」与「界面上此刻选的是哪个环境」恒等 ——
    /// 拿它去断言，把身份实现成"按环境反查"也照样通过。
    /// 只有两条流水线号不同，这个 bug 才露得出来。
    private static let otherPipeline = "5000002"

    private static let splitConfig = BuildConfig(
        yunxiaoDomain: "https://openapi-rdc.aliyuncs.com",
        organizationId: org,
        pipelines: ["test": pipeline, "release": otherPipeline]
    )

    private static let repoURL = "https://codeup.aliyun.com/\(org)/example-group/ExampleApp.git"

    /// 流水线详情 —— 带上 `sources`，否则触发时会因为拿不到仓库地址而直接报错。
    private static let pipelineInfoPayload = """
    {"name":"Example-App-Android","id":5000001,"pipelineConfigId":3000001,
     "pipelineConfig":{
       "version":35,
       "sources":[
         {"type":"codeup","label":"example-group/ExampleApp",
          "data":{"branch":"test","repo":"\(repoURL)"}}
       ]}}
    """

    private static func runPayload(id: Int, status: String) -> String {
        """
        {"pipelineRunId":\(id),"pipelineId":5000001,"status":"\(status)",
         "triggerMode":4,"createTime":1790046747000,"updateTime":1790046749000,
         "creatorAccountId":"","stages":[]}
        """
    }

    /// 终态运行的详情：轮询到 SUCCESS 之后，取 `jobId` 就是从这里读的。
    private static func runDetailPayload(id: Int) -> String {
        """
        {"pipelineRunId":\(id),"pipelineId":5000001,"status":"SUCCESS",
         "triggerMode":4,"createTime":1790046747000,"updateTime":1790046749000,
         "stages":[{"stageInfo":{"jobs":[
            {"id":111111111,"name":"代码检查"},
            {"id":6000001,"name":"编译并构建上传"}
         ]}}]}
        """
    }

    /// 终态步骤列表（名字带耗时后缀，真实原文）。
    private static let stepsPayload = """
    [{"buildId":7000001,"jobId":6000001,
      "buildProcessNodes":[
        {"nodeName":"克隆代码(6s)","stepName":"克隆代码(6s)","stepIndex":2},
        {"nodeName":"执行命令(331s)","stepName":"执行命令(331s)","stepIndex":4},
        {"nodeName":"缓存上传(28s)","stepName":"缓存上传(28s)","stepIndex":5}
      ]}]
    """

    /// 日志应答。`logs` 是服务端给的整段文本。
    private static func logPayload(_ logs: String) -> String {
        #"{"last":-1,"logs":"\#(logs)","more":false}"#
    }

    /// 带产物标记的日志 —— 两个标记都换成真实形状的地址，不含任何敏感信息。
    private static let logWithArtifacts = logPayload(
        #"上传完成->https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk\n"#
            + #"二维码地址->https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png"#
    )

    /// 跑完但日志里一个产物标记都没有。
    private static let logWithoutArtifacts = logPayload("BUILD SUCCESSFUL in 4m 12s")

    /// 本次运行的步骤列表路径。`6000001` 是「编译并构建上传」这个 Job 的真实 ID。
    private static func stepsPath(runID: Int, base: String = BuildViewModelTests.base) -> String {
        "\(base)/pipelineRuns/\(runID)/jobs/6000001/steps"
    }

    /// 本次运行的步骤日志路径。
    ///
    /// 单独提出来是因为它被三处用到（跑通、重试、重试到底），
    /// 每处手写一遍的话，改错其中一处的表现是"这个用例莫名失败"，
    /// 而不是路径拼错了。
    private static func logPath(runID: Int, base: String = BuildViewModelTests.base) -> String {
        "\(base)/pipelineRuns/\(runID)/jobs/6000001/step/log"
    }

    private static let historyPayload = """
    [{"pipelineRunId":30,"pipelineId":5000001,"status":"SUCCESS",
      "startTime":1790046747000,"endTime":1790047099000,
      "triggerMode":4,"creatorAccountId":"example-account-1"}]
    """

    private static func makeViewModel(
        api: StubAPIClient,
        codeup: StubCodeupService = StubCodeupService(),
        config explicitConfig: BuildConfig? = nil,
        resultParsing: AppConfiguration.ResultParsing = .standard
    ) -> BuildViewModel {
        // 先把配置取成局部常量再交给闭包：`Self.config` 是 MainActor 隔离的静态属性，
        // 而 `configProvider` 是一个非隔离的 `@Sendable` 闭包，直接引用会编译不过。
        let config = explicitConfig ?? Self.config
        let flowService = FlowService(api: api, config: { config })
        // 「产物怎么找」现在整个在 `BuildService` 里，所以日志解析器与重试节奏
        // 都注入到它而不是 ViewModel —— ViewModel 已经不认识这两个概念了。
        return BuildViewModel(
            flowService: flowService,
            codeupService: codeup,
            buildService: BuildService(
                flowService: flowService,
                parser: BuildLogParser(),
                resultParsing: resultParsing
            )
        )
    }

    /// 让整条流水线一次跑通的应答装配。
    ///
    /// 从触发到产物一共要打 5 个接口，路径各不相同；这里一次配齐，
    /// 免得每个用例都把这 5 行抄一遍 —— 抄漏一行会表现为"某个用例莫名其妙失败"。
    ///
    /// ⚠️ `…/runs` 这个路径**触发（POST）与历史记录（GET）共用**，
    /// 所以必须按方法分开 stub：混在一起的话，「触发返回裸数字 41」会被
    /// 拿去当历史记录解码，失败又被 `refreshHistory` 吞掉，
    /// 最终表现成一句莫名其妙的"历史记录解析失败"。
    private static func stubFullRun(
        api: StubAPIClient,
        runID: Int = 41,
        log: String = BuildViewModelTests.logWithArtifacts,
        base: String = BuildViewModelTests.base
    ) {
        api.stub(path: base, .success(Self.pipelineInfoPayload))
        api.stub(method: "POST", path: "\(base)/runs", .success(String(runID)))
        api.stub(method: "GET", path: "\(base)/runs", .success(Self.historyPayload))
        api.stub(path: "\(base)/runs/\(runID)", .success(Self.runDetailPayload(id: runID)))
        api.stub(path: Self.stepsPath(runID: runID, base: base), .success(Self.stepsPayload))
        api.stub(path: Self.logPath(runID: runID, base: base), .success(log))
    }

    /// 测试用的重试节奏：次数照旧（3 次），间隔压到毫秒。
    ///
    /// 生产参数是 2 秒一次，用例里等真实秒数会让每个相关用例慢好几秒，
    /// 而且"等到了没有"依赖机器负载，容易变成偶发失败。
    private static let fastRetry = AppConfiguration.ResultParsing(
        maxAttempts: 3,
        delay: .milliseconds(10)
    )

    /// 等到 `condition` 成立，最多等 5 秒。
    ///
    /// 上限给到 5 秒而不是更短：**整条流程里有一次真实的 2 秒等待**
    /// （`Polling.initialDelay`，触发后先等一拍再开始查询状态）。
    /// 这是生产行为，用例不去绕开它，所以等待窗口必须容得下它。
    ///
    /// 用带上限的等待而不是 `while … { await Task.yield() }`：
    /// 后者在断言失败时会变成一个死循环，测试挂住而不报错，比失败更难查。
    private static func waitUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock().now >= deadline {
                Issue.record("等待超时", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 触发打包前的固定动作：**先把分支列表取回来**，再触发。
    ///
    /// 这几个用例测的是打包流程本身（状态机、轮询、产物解析），不是分支获取，
    /// 所以分支走 `StubCodeupService` 的默认应答即可。
    ///
    /// 但取这一次是**必须**的：`startBuild()` 在没选中任何分支时会明确拒绝触发
    /// （见 `triggeringWithoutABranchIsRefused`），不先取分支就会一路走进
    /// "还没有选中代码分支"的失败态 —— 这正是它该有的行为。
    private static func loadBranchesThenStartBuild(_ viewModel: BuildViewModel) async {
        await viewModel.loadBranches()
        viewModel.startBuild()
    }

    // MARK: - 页面数据加载

    @Test("首次进入加载流水线信息与历史记录")
    func loadFetchesPipelineInfoAndHistory() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)", .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .success(Self.historyPayload))

        let viewModel = Self.makeViewModel(api: api)
        await viewModel.loadIfNeeded()

        #expect(viewModel.pipelineInfo?.name == "Example-App-Android")
        #expect(viewModel.pipelineInfo?.version == 35)
        #expect(viewModel.history.map(\.pipelineRunId) == [30])
        #expect(viewModel.loadErrorMessage == nil)
    }

    @Test("再次出现（例如从配置页切回来）不重复请求，已有数据原样保留")
    func secondAppearanceDoesNotRefetch() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)", .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .success(Self.historyPayload))

        let viewModel = Self.makeViewModel(api: api)
        await viewModel.loadIfNeeded()
        let routesAfterFirstLoad = api.requestedRoutes

        // 切到「Yunxiao 配置」再切回来 —— View 会重新出现并再次调用 loadIfNeeded。
        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(api.requestedRoutes == routesAfterFirstLoad, "切回页面不该重新打接口")
        #expect(viewModel.pipelineInfo != nil)
        #expect(viewModel.history.count == 1)
    }

    @Test("页面数据加载失败时给出错误，但不清空已有内容")
    func loadFailureKeepsExistingData() async throws {
        let api = StubAPIClient()
        api.stub(path: "\(Self.base)/runs", .success(Self.historyPayload))
        // 流水线详情返回一个缺字段的响应 —— 就是"根节点没有 version"那种回归。
        api.stub(path: "\(Self.base)", .success(#"{"name":"n"}"#))

        let viewModel = Self.makeViewModel(api: api)
        await viewModel.loadIfNeeded()

        let message = try #require(viewModel.loadErrorMessage)
        #expect(message.contains("解析失败"), "错误信息应指出是解析问题：\(message)")
        #expect(!viewModel.isLoadingHistory)
    }

    // MARK: - 环境切换

    /// 换环境**不该重取任何数据**。
    ///
    /// test 与 release 指向同一条流水线、同一个仓库、同一批分支、同一份运行
    /// 历史 —— 换环境只改变请求体里 `envs.env` 的取值，服务端返回的数据一个字
    /// 都不会变。此前每次切换都会把流水线详情、历史记录、分支列表清空重取：
    /// 四个接口白打一遍，界面上还会先闪成空列表再填回来。
    ///
    /// 这里断言的是**一个请求都没多打**，而不只是"最后数据还对" ——
    /// 后者在"清空后恰好又取回同样的数据"时也会通过，那就完全没守住这个行为。
    @Test("切换环境不重取分支、历史与流水线信息，一个请求都不多发")
    func switchingEnvironmentRefetchesNothing() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .success(Self.historyPayload))
        // 分支链路上的接口：仓库列表与分支列表。它们若被重取，下面数得出来。
        let codeup = StubCodeupService()

        let viewModel = Self.makeViewModel(api: api, codeup: codeup)
        await viewModel.load()

        let routesAfterFirstLoad = api.requestedRoutes
        let branchesAfterFirstLoad = viewModel.branches
        #expect(!branchesAfterFirstLoad.isEmpty, "前置条件：首次加载应该已经拿到分支")

        // 用户把环境从 test 切到 release。
        viewModel.environment = .release
        viewModel.environmentDidChange()
        // 等一小会，让"如果实现去重取"的那个请求有机会发出来。
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            api.requestedRoutes == routesAfterFirstLoad,
            "换环境不该重打接口，多出来的：\(api.requestedRoutes.dropFirst(routesAfterFirstLoad.count))"
        )
        #expect(
            codeup.requestedRepositoryIDs == [8000001],
            "换环境不该重取分支，实际请求了：\(codeup.requestedRepositoryIDs)"
        )
        // 界面上的内容原样留着，不闪空白。
        #expect(viewModel.branches == branchesAfterFirstLoad)
        #expect(viewModel.history.map(\.pipelineRunId) == [30])
        #expect(viewModel.selectedBranch == "test", "用户已选的分支不该被重置")
    }

    /// 还没加载过就切环境：该补取一次，不能停在空白页。
    ///
    /// 上一条守的是"别多打请求"，这一条守的是它的反面 ——
    /// 别把"不重取"做成"永远不取"。用户在首屏数据回来之前切一下环境，
    /// 页面仍然必须自己把数据填上。
    @Test("尚未加载过就切换环境时，仍然会去取一次数据")
    func switchingEnvironmentBeforeFirstLoadStillLoads() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(path: "\(Self.base)/runs", .success(Self.historyPayload))

        let viewModel = Self.makeViewModel(api: api)
        // 刻意**不**调用 load()。

        viewModel.environment = .release
        viewModel.environmentDidChange()
        await Self.waitUntil { viewModel.pipelineInfo != nil }

        #expect(viewModel.pipelineInfo?.name == "Example-App-Android")
        #expect(viewModel.history.map(\.pipelineRunId) == [30])
    }

    /// 打包进行中切环境：停掉轮询，避免拿另一条流水线的运行详情来对答案。
    ///
    /// 但**已经结束的结果保留** —— 同一条流水线，换的只是一个标记，
    /// 没有理由把刚拿到的 APK 地址从界面上抹掉。
    @Test("打包进行中切换环境会停止轮询，已结束的结果则保留")
    func switchingEnvironmentWhileRunningStopsPolling() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(method: "POST", path: "\(Self.base)/runs", .success("41"))
        api.stub(method: "GET", path: "\(Self.base)/runs", .success(Self.historyPayload))
        api.stub(path: "\(Self.base)/runs/41", .success(Self.runPayload(id: 41, status: "RUNNING")))

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.pipelineRunId != nil }

        viewModel.environment = .release
        viewModel.environmentDidChange()
        #expect(viewModel.state == .idle, "换环境后不该还挂在上一轮的运行状态上")

        let routesAfterSwitch = api.requestedRoutes.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            api.requestedRoutes.count == routesAfterSwitch,
            "换环境后不该再有轮询请求，多出来的：\(api.requestedRoutes.dropFirst(routesAfterSwitch))"
        )

        // 反过来的一半：已经结束的结果不受换环境影响。
        let done = StubAPIClient()
        Self.stubFullRun(api: done)
        let doneViewModel = Self.makeViewModel(api: done)
        await Self.loadBranchesThenStartBuild(doneViewModel)
        await Self.waitUntil { doneViewModel.state.artifacts != nil }

        doneViewModel.environment = .release
        doneViewModel.environmentDidChange()
        #expect(doneViewModel.artifacts?.apkURL != nil, "换环境不该把已经拿到的产物抹掉")
        #expect(doneViewModel.branches.count == 2, "换环境不该清空分支列表")
    }

    // MARK: - 打包过程

    @Test("触发后立刻带上 Run ID，未查到服务端状态时为 nil")
    func triggeringCarriesRunIDBeforeFirstPoll() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(method: "POST", path: "\(Self.base)/runs", .success("41"))
        api.stub(method: "GET", path: "\(Self.base)/runs", .success(Self.historyPayload))
        api.stub(path: "\(Self.base)/runs/41", .success(Self.runPayload(id: 41, status: "RUNNING")))

        let viewModel = Self.makeViewModel(api: api)
        // 分支先取回来，否则触发会被拒绝（刻意为之，见 `loadBranchesThenStartBuild`）。
        await Self.loadBranchesThenStartBuild(viewModel)

        // 只等第一次请求发出，不等整条流程 —— 后面的步骤由别的测试覆盖。
        await Self.waitUntil { viewModel.state.pipelineRunId != nil }

        #expect(viewModel.state.pipelineRunId == 41)
        #expect(viewModel.state.serverStatus == nil, "还没查到第一个状态时不该编造一个")
        #expect(viewModel.state.displayText.contains("41"))
    }

    @Test("取消后回到空闲态，并且不再继续请求")
    func cancelStopsPollingAndResets() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(method: "POST", path: "\(Self.base)/runs", .success("42"))
        api.stub(method: "GET", path: "\(Self.base)/runs", .success(Self.historyPayload))
        api.stub(path: "\(Self.base)/runs/42", .success(Self.runPayload(id: 42, status: "RUNNING")))

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.pipelineRunId != nil }

        viewModel.cancel()
        #expect(viewModel.state == .idle)
        #expect(!viewModel.isRunning)

        // 取消后再等一会，确认没有新的状态查询发出去。
        let routesAfterCancel = api.requestedRoutes.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(api.requestedRoutes.count == routesAfterCancel, "取消后不该再有轮询请求")
    }

    // MARK: - 分支 × 环境

    /// 分支列表必须**来自接口**，一个取值都不是写死的。
    ///
    /// 这条用例直接对着这次修复的核心：曾经界面上列的是本地枚举的
    /// `test` / `release`，而真实仓库里的分支（例如
    /// `release/release-20250101`）根本列不出来。
    @Test("分支列表来自 Codeup 接口，选中的默认项也来自接口里的默认分支标记")
    func branchesComeFromTheAPI() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        let codeup = StubCodeupService()

        let viewModel = Self.makeViewModel(api: api, codeup: codeup)
        await viewModel.loadBranches()

        #expect(
            viewModel.branches.map(\.name) == ["test", "release/release-20250101"],
            "分支列表必须原样来自接口，且默认分支排在最前"
        )
        #expect(viewModel.selectedBranch == "test", "没选过时落在默认分支上")
        #expect(viewModel.branchError == nil)

        // ⚠️ repositoryId 是**匹配出来的**，不是常量：
        // 流水线里的仓库地址 → 仓库列表 → 匹配 → repositoryId → 分支接口。
        #expect(
            codeup.requestedRepositoryIDs == [8000001],
            "取分支用的 repositoryId 必须来自仓库匹配，实际请求了：\(codeup.requestedRepositoryIDs)"
        )
    }

    /// 用户在界面上选的两项必须**原样**落到触发请求体里。
    ///
    /// 这是端到端里最容易被静默做错的一环：分支选错不会报错，
    /// 只会构建出另一个分支的包，而界面上一路显示"构建成功"。
    /// **这正是本次修复的那个 bug** —— 曾经触发时读的是一个写死的
    /// `AppConfiguration.Branch` 枚举，界面上选的 `selectedBranch` 被整个丢掉，
    /// 于是不管选哪个分支，构建的都是 `test`。
    ///
    /// 因此这里选的是**带斜杠的真实分支名**：它既证明"选中的分支确实进了请求体"，
    /// 也证明"分支名不是从一个有限的枚举里来的"（枚举根本写不出这个值）。
    @Test("界面上选的分支与环境原样进入触发请求体，交叉组合也成立")
    func branchAndEnvironmentReachTheTriggerBody() async throws {
        for (branch, environment) in [
            ("release/release-20250101", AppConfiguration.Environment.release),
            ("release/release-20250101", AppConfiguration.Environment.test),
            ("test", AppConfiguration.Environment.release),
        ] {
            let api = StubAPIClient()
            Self.stubFullRun(api: api)
            let viewModel = Self.makeViewModel(api: api)
            await viewModel.loadBranches()
            // 模拟用户在 Picker 里选中这一项。
            viewModel.selectedBranch = branch
            viewModel.environment = environment

            viewModel.startBuild()
            await Self.waitUntil { viewModel.state.artifacts != nil }

            // 最后一次带 body 的请求就是触发。
            let body = try #require(
                api.seenBodies.last,
                "分支 \(branch) / 环境 \(environment.rawValue)：没观察到触发请求体"
            )
            // ⚠️ 这里断言的是**报文形状**，不只是字段取值：
            // 服务端要的是 `{"params": "<一段 JSON 文本>"}`，
            // `params` 必须是字符串而不是嵌套对象。写成对象在客户端一样能编译、
            // 一样能发出去，只是服务端会把它当空参数 —— 于是默默地按默认分支构建。
            struct Envelope: Decodable { let params: String }
            let envelope = try JSONDecoder().decode(Envelope.self, from: body)
            struct Params: Decodable {
                let runningBranchs: [String: String]
                let envs: [String: String]
            }
            let decoded = try JSONDecoder().decode(Params.self, from: Data(envelope.params.utf8))

            let label = "分支 \(branch) / 环境 \(environment.rawValue)"
            #expect(decoded.runningBranchs == [Self.repoURL: branch], "\(label)：分支没落到请求体")
            #expect(decoded.envs == ["env": environment.rawValue], "\(label)：环境没落到请求体")
        }
    }

    /// 没选中分支时**明确报错**，不退回任何默认分支。
    ///
    /// 这条守的是"默认值兜底"这条退路：只要还留着"没选就按 test 构建"，
    /// 用户就会遇到"我明明选了别的分支，构建出来的还是 test"，
    /// 而界面上一切正常。宁可明确失败。
    @Test("没有选中分支时拒绝触发，且不发任何触发请求")
    func triggeringWithoutABranchIsRefused() async throws {
        let api = StubAPIClient()
        Self.stubFullRun(api: api)

        let viewModel = Self.makeViewModel(api: api)
        // 刻意**不**加载分支，也不设置 selectedBranch。
        #expect(viewModel.selectedBranch == nil)

        viewModel.startBuild()
        await Self.waitUntil { viewModel.state.message != nil }

        let message = try #require(viewModel.state.message)
        #expect(message.contains("分支"), "错误信息应指出缺的是分支选择：\(message)")
        // 关键：**一个触发请求都没发出去**。宁可不打包，也不能构建一个用户没选过的分支。
        #expect(
            !api.requestedRoutes.contains("POST \(Self.base)/runs"),
            "没选分支时不该发出触发请求，实际请求了：\(api.requestedRoutes)"
        )
    }

    // MARK: - 结果解析

    @Test("整条链路跑通：状态 SUCCESS 后解析出 APK 与二维码地址")
    func fullRunResolvesArtifacts() async throws {
        let api = StubAPIClient()
        Self.stubFullRun(api: api)

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.artifacts != nil }

        let artifacts = try #require(viewModel.artifacts)
        #expect(artifacts.apkURL?.absoluteString.hasSuffix("ExampleApp_debug_v1.0.0.apk") == true)
        #expect(artifacts.qrCodeURL?.absoluteString.hasSuffix("ExampleApp_debug_v1.0.0_qrcode.png") == true)
        // 落到的必须是**成功**态，不是失败态。
        if case .success = viewModel.state {} else {
            Issue.record("期望 .success，实际是 \(viewModel.state)")
        }

        // 日志请求带的是本次运行的真实 ID 与从 steps 里查到的 buildId。
        //
        // ⚠️ 按路径取查询参数，不用 `requestedQuery`（那是"最后一次请求"）：
        // 解析完产物之后流程还会再刷一次历史记录，那时最后一次请求已经
        // 变成历史接口了，参数是空的 —— 断言会以一种"参数没带上"的假象失败。
        let logQuery = api.requestedQuery(forPath: Self.logPath(runID: 41))
        #expect(logQuery["buildId"] == "7000001")
        #expect(logQuery["stepIndex"] == "4")
        #expect(logQuery["offset"] == "0")
        #expect(logQuery["limit"] == "10000")
    }

    /// 这次运行的日志一开始读不到产物标记，第二次才有。
    ///
    /// 模拟的是真机上最常见的一种情形：流水线状态已经 `SUCCESS`，
    /// 但日志文件还有最后一次刷盘没落定，末尾几行（产物标记就在那里）还没写进去。
    /// 一次读不到就判"没有产物"，会把一次成功的构建说成异常。
    @Test("日志第一次没有产物标记时会重试，第二次读到就正常返回")
    func artifactsAreRetriedWhenTheLogIsNotFlushedYet() async throws {
        let api = StubAPIClient()
        let logPath = Self.logPath(runID: 41)
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(method: "POST", path: "\(Self.base)/runs", .success("41"))
        api.stub(method: "GET", path: "\(Self.base)/runs", .success(Self.historyPayload))
        api.stub(path: "\(Self.base)/runs/41", .success(Self.runDetailPayload(id: 41)))
        api.stub(path: Self.stepsPath(runID: 41), .success(Self.stepsPayload))
        // 第一次：还没刷完；第二次起：完整日志。
        api.stubSequence(path: logPath, [
            .success(Self.logWithoutArtifacts),
            .success(Self.logWithArtifacts),
        ])

        let viewModel = Self.makeViewModel(api: api, resultParsing: Self.fastRetry)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.artifacts != nil }

        let artifacts = try #require(viewModel.artifacts)
        #expect(artifacts.apkURL != nil, "重试之后应该拿到产物")
        // 确认真的读了两次 —— 否则这个用例可以在"根本没重试"的实现下通过。
        #expect(
            api.requestedPaths.filter { $0 == logPath }.count == 2,
            "没有重试读取日志，实际读了 \(api.requestedPaths.filter { $0 == logPath }.count) 次"
        )
    }

    /// 标记**真的不存在**时必须停下来。
    ///
    /// 这与上一个用例是一对：重试是有限次的，不是"等到出现为止"。
    /// 打包脚本若不再输出产物标记，重试多少次都不会出现，
    /// 无限循环只会让界面永远转圈、用户既看不到成功也看不到失败。
    @Test("标记始终不存在时重试有限次后停下，状态仍是成功而不是失败")
    func missingArtifactsStopAfterFiniteRetries() async throws {
        let api = StubAPIClient()
        let logPath = Self.logPath(runID: 41)
        Self.stubFullRun(api: api, log: Self.logWithoutArtifacts)

        let viewModel = Self.makeViewModel(api: api, resultParsing: Self.fastRetry)
        await Self.loadBranchesThenStartBuild(viewModel)
        // 等它停下来：整条流程结束（不再是运行中态），而不是等产物出现。
        await Self.waitUntil {
            if case .success = viewModel.state { return true }
            return false
        }

        // ⚠️ 服务端状态原文是 SUCCESS，这里**不能**变成 .failed ——
        // 说成"构建失败"会引导用户去重跑一次已经跑成功的流水线。
        if case .success = viewModel.state {} else {
            Issue.record("期望停在 .success（无产物），实际是 \(viewModel.state)")
        }
        #expect(viewModel.artifacts?.isEmpty == true, "没有标记时不该编造出产物地址")

        // 试满 `maxAttempts` 就停 —— 不是无限等。
        let attempts = api.requestedPaths.filter { $0 == logPath }.count
        #expect(attempts == Self.fastRetry.maxAttempts, "重试次数不对：\(attempts)")
    }

    // MARK: - 当前构建（结果页的入口）

    /// 触发成功就必须把"这一次运行"记下来。
    ///
    /// 守的是结果页的**入口**：界面靠这个值去问服务端"那一次的结果是什么"。
    /// 它一旦丢了，界面上就是一片空白 —— 而这是 `BuildState` 表达不了的，
    /// `.success` 只装产物（见 `BuildState.success`），流水线 ID 与运行 ID
    /// 到那时都已经不在状态机里了。
    @Test("触发成功后立刻记下本次运行的 Run ID 与流水线 ID")
    func triggeringRecordsCurrentBuildRun() async throws {
        let api = StubAPIClient()
        Self.stubFullRun(api: api)

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.currentBuildRun != nil }

        let current = try #require(viewModel.currentBuildRun)
        #expect(current.pipelineRunId == 41, "记下的必须是触发接口返回的那个 ID")
        #expect(current.pipelineId == Self.pipeline)
    }

    /// 记下来的流水线必须是**这次触发实际打到的那一条**。
    ///
    /// 这条是 `environment → pipelineId` 那次迁移的核心看门人。
    /// 身份一旦退化成"记住当时选的是哪个环境、事后按环境反查流水线"，
    /// 用户切一次 Picker 再点进这条历史运行，问到的就是**另一条流水线**上的
    /// 同一个 run 序号 —— 那根本不是这一次运行，而界面上会正常显示一个
    /// APK 地址，看不出任何异常。
    ///
    /// ⚠️ 用的配置必须让 `test` 与 `release` 指向**两条不同的流水线**。
    /// 生产配置里两个环境恰好同号（都是 `5000001`），"跟着流水线走"与
    /// "跟着环境走"在那份配置下结果恒等，这个 bug 露不出来。
    @Test("切换环境后触发，记下的是实际打到的那条流水线，不是默认值")
    func currentBuildRunKeepsThePipelineItWasTriggeredWith() async throws {
        let releaseBase = "/oapi/v1/flow/organizations/\(Self.org)/pipelines/\(Self.otherPipeline)"
        let api = StubAPIClient()
        Self.stubFullRun(api: api, base: releaseBase)

        let viewModel = Self.makeViewModel(api: api, config: Self.splitConfig)
        // ⚠️ 顺序要紧：**先把环境切到 release，再取分支**。
        // 分支链路的第一步是「按当前环境取流水线详情」，在 `test` 下它会去问
        // `5000001`，而这份用例只 stub 了 release 那条流水线 —— 取不到分支，
        // `startBuild()` 会被"没选分支"拦下，触发请求根本没发出去。
        viewModel.environment = .release
        await viewModel.loadBranches()

        viewModel.startBuild()
        await Self.waitUntil { viewModel.currentBuildRun != nil }

        let current = try #require(viewModel.currentBuildRun)
        #expect(current.pipelineId == Self.otherPipeline)
        #expect(current.pipelineId != Self.pipeline, "默认值不该把它覆盖掉")
        // 请求确实打到了 release 那条流水线上 —— 否则上面的断言只是
        // 在验"我们记下了配置里 release 对应的号"，而不是"记下了实际发的号"。
        #expect(
            api.requestedRoutes.contains("POST \(releaseBase)/runs"),
            "触发没打到 release 那条流水线上，实际请求了 \(api.requestedRoutes)"
        )
    }

    /// 身份跟着**这一次运行**走，不跟着界面此刻的选择走。
    ///
    /// 触发在 `release` 下发生，之后用户把 Picker 切回 `test` ——
    /// 已经在跑的这一条运行属于哪条流水线是**既成事实**，不该被后来的
    /// 界面操作改写。这也正是"环境推不出流水线"这个 bug 最隐蔽的形态：
    /// 用户切一次 Picker，屏幕上那张卡片就悄悄指向了另一条流水线。
    ///
    /// 这里等整条流程跑完再切，是因为打包进行中切环境本来就会 `reset()`
    /// （见 `environmentDidChange` 的注释），那是另一件事；
    /// 这条用例要钉的是"跑完之后身份仍不被界面改写"。
    @Test("跑完之后切换环境，不改变已经记下的流水线身份")
    func switchingEnvironmentDoesNotRewriteTheRecordedIdentity() async throws {
        let releaseBase = "/oapi/v1/flow/organizations/\(Self.org)/pipelines/\(Self.otherPipeline)"
        let api = StubAPIClient()
        Self.stubFullRun(api: api, base: releaseBase)

        let viewModel = Self.makeViewModel(api: api, config: Self.splitConfig)
        // 先切环境再取分支 —— 分支链路要按当前环境去取流水线详情，
        // 而这里只 stub 了 release 那条流水线（见上一条用例的注释）。
        viewModel.environment = .release
        await viewModel.loadBranches()

        viewModel.startBuild()
        await Self.waitUntil { viewModel.state.artifacts != nil }

        // 这一趟跑完了，用户把 Picker 切回 test。
        viewModel.environment = .test
        viewModel.environmentDidChange()

        let current = try #require(viewModel.currentBuildRun)
        #expect(
            current.pipelineId == Self.otherPipeline,
            "这一次运行是在 release 上触发的，不该因为 Picker 切走就改成 test 的流水线"
        )
    }

    /// 记下来的这次运行**不会**被后面的成功态抹掉，产物也照旧留在状态机里。
    ///
    /// 这条同时钉住两件事：换结果 UI 不改 `BuildState` 的语义
    /// （`.success` 仍然带着解析出来的产物），以及结果页的入口在整个流程
    /// 跑完之后仍然可用。
    @Test("整条流程跑完后本次运行仍在，且 BuildState 的成功态语义不变")
    func currentBuildRunSurvivesTheSuccessOutcome() async throws {
        let api = StubAPIClient()
        Self.stubFullRun(api: api)

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.artifacts != nil }

        // 状态机那一侧：还是 `.success`，还是带着产物 —— 没有因为换了结果 UI
        // 就被改成"只装一个 run ID"。
        guard case .success(let artifacts) = viewModel.state else {
            Issue.record("期望 .success，实际是 \(viewModel.state)")
            return
        }
        #expect(artifacts.apkURL != nil, "成功态里的产物不该丢失")
        #expect(viewModel.artifacts?.qrCodeURL != nil)

        // 结果页入口那一侧：运行 ID 与流水线 ID 都还在。
        let current = try #require(viewModel.currentBuildRun)
        #expect(current.pipelineRunId == 41)
        #expect(current.pipelineId == Self.pipeline)
    }

    /// 失败分两种，**只有一种**该留下"本次运行"。
    ///
    /// - 触发**之前**就失败（没选分支 / 触发请求本身挂了）：服务端上压根没有
    ///   这一次运行，这时候记一个就是凭空造出一个不存在的 run。
    /// - 触发**之后**失败（轮询到 FAIL）：那一次运行是**真实存在**的，
    ///   用户正需要点进去看它到底失败在哪，把它清掉反而是错的。
    @Test("没形成运行的失败不留记录；触发之后才失败的运行要留着")
    func failureOnlyKeepsRunsThatActuallyExist() async throws {
        // ① 没选分支 → 触发请求都没发出去 → 不该有任何"本次运行"。
        let refusedAPI = StubAPIClient()
        Self.stubFullRun(api: refusedAPI)
        let refused = Self.makeViewModel(api: refusedAPI)

        refused.startBuild()
        await Self.waitUntil { refused.state.message != nil }

        #expect(refused.state.message != nil, "没选分支应该明确报错")
        #expect(refused.currentBuildRun == nil, "服务端上没有这一次运行，不该编造一个")
        #expect(!refusedAPI.requestedRoutes.contains("POST \(Self.base)/runs"))

        // ② 触发成功、但流水线跑成了 FAIL → 这一次运行确实存在，必须留着。
        let failedAPI = StubAPIClient()
        failedAPI.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        failedAPI.stub(method: "POST", path: "\(Self.base)/runs", .success("41"))
        failedAPI.stub(method: "GET", path: "\(Self.base)/runs", .success(Self.historyPayload))
        failedAPI.stub(path: "\(Self.base)/runs/41", .success(Self.runPayload(id: 41, status: "FAIL")))

        let failed = Self.makeViewModel(api: failedAPI)
        await Self.loadBranchesThenStartBuild(failed)
        await Self.waitUntil { failed.state.message != nil }

        #expect(failed.state.message != nil, "FAIL 应该报出来")
        let current = try #require(
            failed.currentBuildRun,
            "触发已经成功，这一次运行是真实存在的，不该因为结果是 FAIL 就抹掉"
        )
        #expect(current.pipelineRunId == 41)
        #expect(current.pipelineId == Self.pipeline)
    }

    /// 重新打包：记录必须换成**第二次**那一次运行。
    ///
    /// 留下来的是上一次的 ID 的话，界面上会挂着一张属于上一次运行的卡片 ——
    /// 它会正常显示一个 APK 地址，看起来完全正常，只是那个包不是刚打的。
    @Test("重新打包时当前运行更新成第二次，并且先从第一次的成功态清干净")
    func restartingBuildMovesCurrentBuildRunToTheSecondRun() async throws {
        let api = StubAPIClient()
        Self.stubFullRun(api: api, runID: 41)

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.artifacts != nil }
        #expect(viewModel.currentBuildRun?.pipelineRunId == 41)

        // 第二次打包：触发接口改回 42，整条链路的应答一并换掉。
        Self.stubFullRun(api: api, runID: 42)
        viewModel.startBuild()

        // 触发是异步的：`startBuild()` 一返回就断言，等于在断言一个还没发生的写入。
        await Self.waitUntil { viewModel.currentBuildRun?.pipelineRunId == 42 }
        #expect(
            viewModel.currentBuildRun == CurrentBuildRun(pipelineRunId: 42, pipelineId: Self.pipeline),
            "实际是 \(String(describing: viewModel.currentBuildRun))"
        )
    }

    // MARK: - 结果页的挂载闸门

    /// 结果页**只在流程停下之后**才允许挂载。
    ///
    /// 这条闸门修的是真机上那个「打包记录里明明已经跑完、结果页却一直停在构建中」：
    /// `BuildResultView` 是快照式的（挂载时打一次接口，之后不再重问），
    /// 而 `currentBuildRun` 在**触发一成功**就有值了 —— 那一刻服务端上的运行
    /// 还在 RUNNING，先挂上去就把 `RUNNING` + 空产物那个快照定了型，
    /// 而且再也不会自动纠正。
    @Test("运行期间不给看结果页，跑完之后才放行")
    func resultSectionStaysClosedWhileTheRunIsStillGoing() async throws {
        let api = StubAPIClient()
        Self.stubFullRun(api: api)

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)

        // 触发已经成功（身份有了），但轮询还没问出结果 —— `poll` 头一件事是先等
        // 一拍（`Polling.initialDelay`），所以这一段是稳定可观察的窗口。
        await Self.waitUntil { viewModel.currentBuildRun != nil }
        #expect(viewModel.isRunning, "此刻流程仍在跑")
        #expect(
            !viewModel.currentBuildRunHasStopped,
            "运行期间挂着结果页，它快照到的就是 RUNNING，界面会一直停在「构建中」"
        )

        await Self.waitUntil { !viewModel.isRunning }
        #expect(viewModel.currentBuildRunHasStopped)
        #expect(viewModel.currentBuildRun?.pipelineRunId == 41)
    }

    /// 闸门是「流程停下」，**不是**「构建成功」。
    ///
    /// FAIL / CANCELED / 轮询超时这三种收场下 `state` 都是 `.failed`，
    /// 但服务端上确实存在一次真实的运行 —— 用户正需要点进去看它的状态原文。
    /// 把闸门写成"成功才给看"，这三种情况的结果页会一起消失。
    @Test("失败的运行同样放行：闸门看的是流程停没停，不是成没成")
    func resultSectionOpensForFailedRunsToo() async throws {
        let api = StubAPIClient()
        api.stub(path: Self.base, .success(Self.pipelineInfoPayload))
        api.stub(method: "POST", path: "\(Self.base)/runs", .success("41"))
        api.stub(method: "GET", path: "\(Self.base)/runs", .success(Self.historyPayload))
        api.stub(path: "\(Self.base)/runs/41", .success(Self.runPayload(id: 41, status: "FAIL")))

        let viewModel = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(viewModel)
        await Self.waitUntil { viewModel.state.message != nil }

        #expect(!viewModel.isRunning)
        #expect(
            viewModel.currentBuildRunHasStopped,
            "FAIL 也是一次真实存在的运行，结果页要能打开"
        )
        #expect(viewModel.currentBuildRun?.pipelineRunId == 41)
    }

    /// 闸门另一侧：服务端上压根**没有**这一次运行时，永远不放行 ——
    /// 不能出现「没有运行却挂出一张结果页」。
    @Test("没形成运行的失败与主动取消都不放行")
    func resultSectionStaysClosedWhenThereIsNoRun() async throws {
        // ① 没选分支：触发请求都没发出去，服务端上没有这一次运行。
        let refused = Self.makeViewModel(api: StubAPIClient())
        refused.startBuild()
        await Self.waitUntil { refused.state.message != nil }

        #expect(refused.currentBuildRun == nil, "服务端上没有这一次运行，不该编造一个")
        #expect(!refused.currentBuildRunHasStopped)

        // ② 打包中途取消：身份被清掉，同样不该再挂结果页。
        let api = StubAPIClient()
        Self.stubFullRun(api: api)
        let canceled = Self.makeViewModel(api: api)
        await Self.loadBranchesThenStartBuild(canceled)
        await Self.waitUntil { canceled.currentBuildRun != nil }

        canceled.cancel()

        #expect(canceled.currentBuildRun == nil)
        #expect(!canceled.currentBuildRunHasStopped)
    }

    // MARK: - 状态文案

    @Test("轮询期间界面展示服务端返回的状态原文")
    func runningStateShowsServerStatusVerbatim() {
        let state = BuildState.running(pipelineRunId: 35, serverStatus: "RUNNING")

        #expect(state.pipelineRunId == 35)
        #expect(state.serverStatus == "RUNNING")
        #expect(state.displayText.contains("RUNNING"))
        #expect(state.isRunning)
    }
}
