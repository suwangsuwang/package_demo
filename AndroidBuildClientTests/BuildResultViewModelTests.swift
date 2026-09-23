import Foundation
import Testing

@testable import AndroidBuildClient

/// `BuildResultViewModel` 的测试 —— **状态映射**，不是界面。
///
/// 这一层最要紧的规则只有一条：**产物只在成功终态才可见**。
/// 它之所以值得写成测试，是因为它失效时的表现非常隐蔽 ——
/// 认不出的状态值被当成成功，界面上就会显示一个属于**另一次运行**的
/// APK 地址，而且看起来完全正常。
///
/// 因此这里刻意有两条独立的防线用例：
/// - 「认不出的状态」用例走的是真实的 `BuildService` 行为（产物为空）；
/// - 「认不出的状态 + 人工注入非空产物」用例直接构造一个 `BuildResult`，
///   绕开 `BuildService` 当前的保证。
/// 后者是前者的兜底：即便将来 `BuildService` 的第一道闸失效，这一层仍然挡住。
///
/// 不碰网络、不碰 SwiftUI：`StubBuildService` 直接给一份结果。
@Suite("BuildResultViewModel")
@MainActor
struct BuildResultViewModelTests {

    // MARK: - 夹具

    private static let runID = 30

    /// 这次运行所属的流水线。**与 `runID` 一起构成一次运行的完整身份**，
    /// 两个都得原样传给 `BuildService` —— 传错 `pipelineId` 不会编译失败，
    /// 只会静默地去问另一条流水线。
    private static let pipeline = "5000001"

    private static let apkURL = URL(
        string: "https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk"
    )!
    private static let qrCodeURL = URL(
        string: "https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png"
    )!

    /// 一篇完整的成功结果：两个产物地址都在。
    private static let fullArtifacts = BuildArtifacts(
        apkURL: apkURL,
        qrCodeURL: qrCodeURL
    )

    /// 服务端原文就是 `SUCCESS`，只是日志里两个标记都没解析到。
    private static let successWithoutArtifacts = BuildResult(
        pipelineRunId: runID,
        status: "SUCCESS",
        createdAt: 1_790_046_747_000,
        artifacts: BuildArtifacts()
    )

    private static func result(
        status: String,
        artifacts: BuildArtifacts = BuildArtifacts()
    ) -> BuildResult {
        BuildResult(
            pipelineRunId: runID,
            status: status,
            createdAt: 1_790_046_747_000,
            artifacts: artifacts
        )
    }

    /// 造一个只返回固定结果的 ViewModel，并顺手断言它确实被调用了一次。
    private static func makeViewModel(
        result: BuildResult
    ) -> (BuildResultViewModel, StubBuildService) {
        let stub = StubBuildService(result: result)
        return (BuildResultViewModel(buildService: stub), stub)
    }

    // MARK: - 初始状态

    @Test("初始状态：没有结果、不在加载、没有错误")
    func initialStateIsEmpty() {
        let (viewModel, _) = Self.makeViewModel(result: Self.successWithoutArtifacts)

        #expect(viewModel.result == nil)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.runStatus == nil)
        #expect(viewModel.visibleArtifacts == nil)
    }

    // MARK: - 成功

    @Test("SUCCESS + 两个产物：状态是成功，两个地址都可见")
    func successfulRunExposesArtifacts() async {
        let (viewModel, _) = Self.makeViewModel(
            result: Self.result(status: "SUCCESS", artifacts: Self.fullArtifacts)
        )

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.isLoading == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.runStatus == .succeeded)
        #expect(viewModel.result?.pipelineRunId == Self.runID)
        #expect(viewModel.result?.createdAt == 1_790_046_747_000)
        #expect(viewModel.visibleArtifacts?.apkURL == Self.apkURL)
        #expect(viewModel.visibleArtifacts?.qrCodeURL == Self.qrCodeURL)
    }

    // MARK: - 成功但没有产物：仍然是成功

    @Test("SUCCESS 但没有产物：状态仍是成功，只是没有可展示的产物")
    func successfulRunWithoutArtifactsStaysSuccessful() async {
        let (viewModel, _) = Self.makeViewModel(result: Self.successWithoutArtifacts)

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.runStatus == .succeeded)
        #expect(viewModel.runStatus != .failed, "服务端原文是 SUCCESS，判成失败会误导用户去重跑")
        #expect(viewModel.result?.isSuccessful == true)
        #expect(viewModel.visibleArtifacts == nil)
    }

    // MARK: - 非成功终态：一律没有产物

    @Test("FAIL：失败，且没有产物")
    func failedRunHasNoArtifacts() async {
        let (viewModel, _) = Self.makeViewModel(result: Self.result(status: "FAIL"))

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.runStatus == .failed)
        #expect(viewModel.result?.isSuccessful == false)
        #expect(viewModel.visibleArtifacts == nil)
    }

    @Test("CANCELED：是取消，不是失败，也没有产物")
    func canceledRunIsNotFailed() async {
        let (viewModel, _) = Self.makeViewModel(result: Self.result(status: "CANCELED"))

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.runStatus == .canceled)
        #expect(viewModel.runStatus != .failed, "取消与失败是两种不同的收场")
        #expect(viewModel.visibleArtifacts == nil)
    }

    @Test("认不出的状态值：既不是成功也不是失败，原样保留服务端原文")
    func unknownStatusIsNeverSuccessful() async {
        let (viewModel, _) = Self.makeViewModel(result: Self.result(status: "QUEUE_PAUSED"))

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.runStatus == .unknown("QUEUE_PAUSED"))
        #expect(viewModel.result?.isSuccessful == false, "认不出 ≠ 成功")
        #expect(viewModel.visibleArtifacts == nil)
    }

    @Test("RUNNING：还在跑，没有产物")
    func runningRunHasNoArtifacts() async {
        let (viewModel, _) = Self.makeViewModel(result: Self.result(status: "RUNNING"))

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.runStatus == .running)
        #expect(viewModel.visibleArtifacts == nil)
    }

    // MARK: - RUNNING 之后的重问

    @Test("RUNNING 之后再 load：真的又打了一次接口，不被「已有结果」挡住")
    func loadingAgainAfterRunningHitsTheServiceTwice() async {
        // ⚠️ 这条用例支撑的是**历史入口的「刷新」按钮**。
        //
        // 结果页是快照式的：`.task` 只在视图身份建立时跑一次。历史记录里完全
        // 可能出现 `RUNNING`（刚触发的那次就在列表里），用户点进去看到
        // "构建中" 后，唯一的出路就是那个刷新按钮 —— 它做的正是再调一次
        // `load`。如果 `load` 里存在"有结果就不再请求"之类的保护，
        // 那条页面就会永久停在构建中，而这条用例会红。
        //
        // 断言的是**调用次数**而不是界面：按钮本身能否点出来属于 UI 验证，
        // 但"再调一次 load 会不会真的重问服务端"必须钉死在测试里。
        let (viewModel, stub) = Self.makeViewModel(result: Self.result(status: "RUNNING"))

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)
        #expect(viewModel.runStatus == .running)
        #expect(stub.callCount == 1)

        // 这一次就是刷新按钮做的事。
        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(stub.callCount == 2, "刷新必须真的重问服务端，而不是被已有结果挡住")
        #expect(viewModel.isLoading == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.runStatus == .running, "重问拿到的仍是最新一次结果")
        #expect(stub.receivedPipelineRunIds == [Self.runID, Self.runID])
        #expect(stub.receivedPipelineIds == [Self.pipeline, Self.pipeline])
    }

    @Test("刷新期间进入加载态：不会把旧结果清成空白")
    func reloadEntersLoadingState() async {
        // 刷新时界面要靠 `isLoading` 表达"正在重问"。这里只能断言它**回到**
        // false（`await` 之后已经结束），但下面这条同样重要：
        // 刷新不该把旧结果清成 nil —— 清掉的话界面会闪一下空白。
        let (viewModel, _) = Self.makeViewModel(result: Self.result(status: "RUNNING"))

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)
        let before = viewModel.result

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.isLoading == false)
        #expect(viewModel.result != nil)
        #expect(viewModel.result == before)
    }

    // MARK: - 第二道闸

    @Test("认不出的状态 + 人工注入的非空产物：产物仍然不可见")
    func unknownStatusHidesInjectedArtifacts() async {
        // ⚠️ 这份 `BuildResult` 是**手工构造**的：`BuildService` 今天不会返回
        // "非成功状态 + 非空产物"的组合。这条用例就是不要依赖那个保证 ——
        // 一旦第一道闸失效（例如将来放宽了 status 判断），这一层必须自己挡住。
        let (viewModel, _) = Self.makeViewModel(
            result: Self.result(status: "QUEUE_PAUSED", artifacts: Self.fullArtifacts)
        )

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.result?.artifacts.isEmpty == false, "结果里确实带着产物")
        #expect(viewModel.visibleArtifacts == nil, "但界面上一个都不许显示")
    }

    // MARK: - 错误

    @Test("服务层抛错：有错误信息、不在加载、没有结果")
    func serviceErrorIsReportedWithoutResult() async {
        let stub = StubBuildService(
            result: Self.successWithoutArtifacts,
            error: FlowServiceError.missingIdentifier("本次运行里没有找到构建 Job")
        )
        let viewModel = BuildResultViewModel(buildService: stub)

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.errorMessage?.isEmpty == false)
        #expect(viewModel.isLoading == false)
        #expect(viewModel.result == nil)
        #expect(viewModel.runStatus == nil)
        #expect(viewModel.visibleArtifacts == nil)
    }

    @Test("取不到结果时的错误信息不含请求头或 Token 字样")
    func errorMessageCarriesNoSecrets() async {
        let stub = StubBuildService(
            result: Self.successWithoutArtifacts,
            error: FlowServiceError.pollingTimedOut(.seconds(600))
        )
        let viewModel = BuildResultViewModel(buildService: stub)

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: Self.pipeline)

        let message = viewModel.errorMessage ?? ""
        // 文案由错误类型自己的 errorDescription 提供，这一层不拼任何请求细节。
        for forbidden in ["token", "Token", "Authorization", "x-yunxiao"] {
            #expect(!message.contains(forbidden), "错误文案里不该出现 \(forbidden)")
        }
    }

    // MARK: - 参数透传

    @Test("pipelineRunId 与 pipelineId 原样传给了 BuildService")
    func loadPassesBothArgumentsThrough() async {
        let (viewModel, stub) = Self.makeViewModel(result: Self.successWithoutArtifacts)

        await viewModel.load(pipelineRunId: 987_654, pipelineId: "2222222")

        // `pipelineId` 标明这次运行属于哪条流水线：传错了不会编译失败，
        // 只会静默地展示另一条流水线的结果，所以必须钉死。
        #expect(stub.calls == [
            StubBuildService.Call(pipelineRunId: 987_654, pipelineId: "2222222")
        ])
    }

    @Test("重新加载：旧的错误被清掉，新结果覆盖旧结果")
    func reloadReplacesPreviousOutcome() async {
        // 第一次抛错、第二次给结果。用序列化的入参触发两种走向，
        // 顺带断言两次调用的参数各自被记下来。
        let stub = StubBuildService(
            result: Self.result(status: "SUCCESS", artifacts: Self.fullArtifacts),
            error: FlowServiceError.missingIdentifier("第一次没取到")
        )
        let viewModel = BuildResultViewModel(buildService: stub)

        await viewModel.load(pipelineRunId: Self.runID, pipelineId: "111")
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.result == nil)

        stub.clearError()
        await viewModel.load(pipelineRunId: Self.runID, pipelineId: "222")

        #expect(viewModel.errorMessage == nil, "重试成功后不该还挂着上一次的错误")
        #expect(viewModel.runStatus == .succeeded)
        #expect(viewModel.visibleArtifacts != nil)
        #expect(stub.receivedPipelineRunIds == [Self.runID, Self.runID])
        // 两次传的是**不同**的流水线号：只有不同，才验得出每次调用都真的
        // 把当次的 `pipelineId` 传了下去，而不是记住了第一次那个。
        #expect(stub.receivedPipelineIds == ["111", "222"])
    }
}
