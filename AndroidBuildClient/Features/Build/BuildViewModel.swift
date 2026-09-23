import Foundation
import Observation

/// **当前这一次构建的身份**：哪条流水线上的哪一次运行。
///
/// ⚠️ **两个字段必须绑在一起，所以它们是一个不可变值类型，而不是 ViewModel 上
/// 两个各自可变的属性。** 分开存的话，用户换了环境而 `pipelineRunId` 还留着
/// 上一轮的值，就会出现"拿上一次的运行 ID 去问这一次的环境的产物"——
/// 这不会编译失败，只会静默地展示另一条流水线的结果，界面上看起来完全正常。
///
/// ⚠️ **存的是 `pipelineId` 而不再是发起时的 `environment`。**
/// 它真正表达的是「**当前这次构建到底是哪一条服务器流水线的哪一次运行**」，
/// 而不是"当时界面上选的是哪个环境"：
/// - `environment` 属于**发起构建时的用户配置** —— 它决定触发请求打到哪条流水线；
/// - `pipelineId` 属于**服务器这次实际运行的身份** —— 一次运行一旦建立，
///   它属于哪条流水线就已经是既成事实。
///
/// 两者的差别在环境与流水线不再一一对应时才会暴露，而那时用 `environment`
/// 去查这条运行的产物会打到**另一条流水线**上，拿到一条 ID 恰好相同、
/// 或干脆不存在的运行 —— 前者是静默取错数据。
///
/// 它**不是** `BuildState` 的一部分，也**不是** `BuildResult`：
/// - `BuildState` 说的是「本客户端的流程走到哪一步」（触发中 / 轮询中 / 取结果中）；
///   它只在 `.running` 期间带着 ID，进入 `.success` 之后 ID 就没了
///   （见 `BuildState.success`：它只装产物）。
/// - `BuildResult` 说的是「服务端上那一次运行的结果」，要拿到它得先知道问哪一次。
///
/// 这一层夹在两者中间：**"去看哪一次运行"**。界面拿它去取结果、去展示。
struct CurrentBuildRun: Equatable, Sendable {

    /// 本次运行的 ID。来自触发接口（`POST …/runs`）的响应体。
    let pipelineRunId: Int

    /// 这条运行所属的流水线 ID。
    ///
    /// **它是"问产物"的入参，不是展示字段** —— 它标明这次运行到底跑在哪条
    /// 流水线上，所以必须与 `pipelineRunId` 同生共死，不能事后跟着界面上的
    /// 环境选择器走。
    ///
    /// ⚠️ 这里的值来自**触发请求实际使用的那条流水线**（`runPipeline` 回传的），
    /// 不是服务端在响应里返回的字段 —— 触发接口的响应体只有一个裸的
    /// `pipelineRunId`。详见 `PipelineRunTriggerResult`。
    ///
    /// 类型是 `String` 而不是 `Int`：配置里的流水线 ID 本来就是字符串
    /// （见 `AppConfiguration.Path` 与 `BuildConfig.pipelineID(for:)`），
    /// 而且与 `pipelineRunId: Int` 类型不同，**两个参数写反了根本编译不过**。
    let pipelineId: String
}

/// Build 页面的状态持有者。
///
/// 只做流程编排 —— 不写任何 HTTP 细节，接口调用全部经由 `FlowService`，
/// 「产物怎么找」整个交给 `BuildService`（它自己再调 `BuildLogParser`）。
///
/// 完整链路（每一步的 ID 都来自上一步的响应，没有一个是常量）：
/// ```
/// GET /pipelines/{id} → sources[].data.repo（触发体的键）
/// POST /runs（body: {"params": "{runningBranchs, envs}"}）→ pipelineRunId
///   → 轮询 GET /runs/{pipelineRunId}（2 秒）直到 SUCCESS
///   → BuildService.fetchBuildResult(pipelineRunId:pipelineId:)  ← 以下全在这一个调用里面
///        ├─ GET /runs/{pipelineRunId} → 状态 / 开始时间 / jobId
///        ├─ GET /pipelineRuns/{id}/jobs/{jobId}/steps →「执行命令」的 stepIndex 与 buildId
///        ├─ GET /pipelineRuns/{id}/jobs/{jobId}/step/log（offset=0&limit=10000）
///        └─ 解析「上传完成->」「二维码地址->」
/// ```
///
/// 分支列表走的是**另一条链路**（与打包流程相互独立）：
/// ```
/// GET /pipelines/{id} → sources[].data.repo（流水线绑定的仓库地址）
///   → GET /codeup/.../repositories（全部分页）→ 按地址匹配 → repositoryId
///   → GET /codeup/.../repositories/{repositoryId}/branches（全部分页）
///   → 界面上的分支 Picker
/// ```
@MainActor
@Observable
final class BuildViewModel {

    /// 当前选择的**构建环境**。
    ///
    /// 环境是本地的固定枚举（它决定用**哪条流水线**，是本地配置里的一个键）；
    /// **分支不是** —— 分支的取值范围由仓库决定，见下面的 `branches`。
    /// 两者在请求体里落在两个不同位置（`runningBranchs` / `envs`），
    /// 因此允许「分支 xxx + 环境 release」这类交叉组合，也**必须**允许。
    var environment: AppConfiguration.Environment = .test

    // MARK: - 代码分支（来自 Codeup，不是固定枚举）

    /// 可选分支。**全部来自接口**，没有任何一个取值是写死的。
    private(set) var branches: [CodeupBranch] = []

    /// 用户选中的分支名。
    ///
    /// ⚠️ **这是触发请求体里 `runningBranchs` 取值的唯一来源。**
    /// 曾经这里还有一个并行的固定枚举 `AppConfiguration.Branch` 供触发使用，
    /// 结果是界面上选了分支、请求体里却始终是那个枚举的默认值 `test` ——
    /// 构建出来的是另一个分支的包，界面上一路显示"构建成功"。
    /// 已删除，不要再引入任何"默认分支"兜底。
    ///
    /// **未加载出分支时为 `nil`** —— 不用一个假的分支名占位，
    /// 否则界面会显示一个并不存在的选中项。此时触发会被明确拒绝
    /// （见 `run()` 里的 `.missingBranchSelection`），而不是退回某个默认分支。
    var selectedBranch: String?

    /// 分支列表是否正在加载。
    private(set) var isLoadingBranches = false

    /// 分支加载失败的原因。成功时清空。
    private(set) var branchError: String?

    private(set) var state: BuildState = .idle

    /// **当前这一次构建**：已经被触发、因此服务端上确实存在的那一次运行。
    ///
    /// 它解决的是一个 `BuildState` 表达不了的问题：`BuildState.success` 只装产物
    /// （见 `BuildState.success` 的注释），所以在整条流程跑完之后，
    /// **本次运行的 ID 与它所属的流水线 ID 就一起丢了** —— 而"构建结果"页恰恰
    /// 需要这两个值才能去问服务端"那一次运行的结果是什么"。
    ///
    /// 生命周期与旧的 `state.artifacts` 完全对齐：
    /// - 触发拿到 ID 时**立即**写入 —— 此后服务端上这一次运行就已经存在了，
    ///   哪怕后面轮询到 FAIL/CANCELED，它也是一次**真实**的运行，不是编造的；
    /// - 开始新一轮、取消、复位时清空 —— 否则界面上会留着上一次的卡片。
    ///
    /// ⚠️ **不在失败路径上写入。** 取不到分支（`.missingBranchSelection`）
    /// 或触发请求本身失败时，服务端上压根没有这一次运行，
    /// 这时写一个进去就是凭空造出一个不存在的 run。
    private(set) var currentBuildRun: CurrentBuildRun?

    /// 流水线信息（名称 / ID / 版本），进入页面时加载。
    private(set) var pipelineInfo: PipelineInfo?
    /// 历史打包记录，进入页面时加载，触发成功后刷新。
    private(set) var history: [PipelineRun] = []
    /// 历史记录是否正在加载（首次进入或刷新时）。
    private(set) var isLoadingHistory = false
    /// 信息加载中的错误（不覆盖打包状态）。
    private(set) var loadErrorMessage: String?
    /// 页面数据是否已经加载过。
    ///
    /// 状态持有者现在挂在 `AppModel` 上，比 View 活得久，
    /// 因此"要不要加载"必须自己记着，不能靠 View 的 `@State` 被销毁来重置 ——
    /// 否则每次从配置页切回来都会重打两个接口。
    @ObservationIgnored
    private var hasLoaded = false

    /// 当前正在进行的任务，重复点击时先取消上一个。
    @ObservationIgnored
    private var task: Task<Void, Never>?

    private let flowService: any FlowServiceProtocol
    /// 代码库 / 分支的来源。分页细节在它内部，这里只拿到完整列表。
    private let codeupService: any CodeupServiceProtocol
    /// 「产物怎么找」的唯一入口。jobId / stepIndex / buildId 这些内部细节全在它下面。
    private let buildService: any BuildServiceProtocol

    init(
        flowService: any FlowServiceProtocol = FlowService(),
        codeupService: any CodeupServiceProtocol = CodeupService(),
        buildService: any BuildServiceProtocol = BuildService()
    ) {
        self.flowService = flowService
        self.codeupService = codeupService
        self.buildService = buildService
    }

    var isRunning: Bool { state.isRunning }

    /// **本次构建是否已经停下来** —— 停下来了才允许去看结果。
    ///
    /// ⚠️ **这条判断说的是「流程走到哪了」，不是「服务端那条运行成不成」。**
    /// 用的是 `isRunning`（`.triggering` / `.running` / `.fetchingResult` 为真），
    /// **不是** `state == .success`：
    /// - 失败、被取消、轮询超时同样要能看到结果页 —— 那三种收场下
    ///   `state` 都是 `.failed`，但服务端上确实存在一次真实的运行，
    ///   用户需要看到它的状态原文。按"成功才给看"来写，这三种情况就全丢了。
    ///
    /// ⚠️ **为什么必须在流程停止前挡住，而不是让结果页自己刷新。**
    /// `BuildResultView` 是**快照式**的：它挂载时打一次接口，之后不再重问
    /// （它的 `@State` ViewModel 只在**视图身份变化**时才重建，`.task` 也只在
    /// 身份变化时才重跑）。而触发一成功 `currentBuildRun` 就有值了 ——
    /// 那一刻服务端上的运行还在 RUNNING，快照下来的就是 `RUNNING` + 空产物。
    /// 于界面就是"打包记录里明明已经跑完，结果页却一直卡在构建中"。
    ///
    /// 所以闸门放在**挂载**这一侧：运行期间这一块根本不出现
    /// （实时状态由 `BuildView.statusSection` 那一行负责展示），
    /// 等到流程停下再首次挂载，那次 `.task` 问到的就是终态快照。
    var currentBuildRunHasStopped: Bool { currentBuildRun != nil && !isRunning }

    /// 最近一次成功解析出的产物。
    ///
    /// ⚠️ **界面已经不再用它了。** 结果展示整个交给了 `BuildResultView`
    /// （它自己去问服务端），这里保留是因为 `BuildState.success` 本来就装着产物，
    /// 去掉等于改动状态机的语义。测试也仍然对着它断言。
    var artifacts: BuildArtifacts? { state.artifacts }

    // MARK: - 页面数据

    /// 加载流水线信息与历史记录。进入页面时调用一次。
    func load() async {
        hasLoaded = true
        loadErrorMessage = nil
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            async let info = flowService.fetchPipelineInfo(environment: environment)
            async let runs = flowService.fetchPipelineRuns(environment: environment)
            pipelineInfo = try await info
            history = try await runs
        } catch {
            loadErrorMessage = Self.message(for: error)
        }

        // 分支列表与上面两个接口**分开报错**：它要经过"流水线详情 → 仓库列表 →
        // 仓库匹配 → 分支列表"四步，任何一步失败都不该把整页数据说成加载失败。
        await loadBranches()
    }

    /// 只在还没加载过时加载。页面每次出现都会调用，但只有第一次真的发请求。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// 只刷新历史记录，不重新拉流水线信息。打包结束后调用。
    ///
    /// 与 `load()` 分开是因为 `load()` 会把 `loadErrorMessage` 清空 ——
    /// 打包过程中若刚刚失败的是一次信息加载，这里不该把那行错误悄悄抹掉。
    private func refreshHistory() async {
        do {
            history = try await flowService.fetchPipelineRuns(environment: environment)
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = Self.message(for: error)
        }
    }

    /// 环境切换后的处理。
    ///
    /// ⚠️ **不强制刷新任何数据。** test 与 release 指向同一条流水线、同一个仓库、
    /// 同一批分支、同一份运行历史 —— 换环境只是换请求体里 `envs.env` 的取值，
    /// 服务端返回的数据一个字都不会变。此前的实现是每次切换都把流水线详情、
    /// 历史记录、分支列表整个清空重取：四个接口白打一遍，界面上还会先闪成
    /// 空列表再填回来。
    ///
    /// 换环境本身**不需要任何数据跟着动**：`environment` 没有副作用，
    /// 它只在真正发请求时作为参数传下去（用它取流水线 ID、拼 `envs.env`）。
    ///
    /// **前提**：配置文件里两个环境配的是同一条流水线。若将来让它们指向不同的
    /// 流水线，这里必须改回"按流水线 ID 判断要不要重取"，否则页面会一直挂着
    /// 上一条流水线的信息与历史。
    func environmentDidChange() {
        // 打包进行中时**仍然停掉轮询**。
        //
        // ⚠️ 这一条在 Phase 5-B 之后**不再是"防止问到另一条流水线"那道闸** ——
        // 轮询与取结果问的都是 `CurrentBuildRun` 里冻结的那个身份
        // （`pipelineId + pipelineRunId`），它不随界面上的环境选择器变化，
        // 所以环境一变就打偏的问题在那一层已经被根治了。
        //
        // 保留它是为了另一件事：`run()` 收尾处的 `refreshHistory()` 走的是
        // **环境级**查询（`fetchPipelineRuns(environment:)`），环境一变，那次
        // 刷新拉回来的就是另一个环境的记录，而页面上这一次运行的身份没变 ——
        // 两边对不上。停在 idle 态再让用户重新开始，比让一次运行的结果
        // 悬在半空清楚。（界面上环境选择器在打包期间本来就是禁用的，这里是第二道闸。）
        //
        // 已经结束的运行结果则**保留**：同一条流水线，换的只是一个标记，
        // 没有理由把刚拿到的 APK 地址从界面上抹掉。
        if isRunning { reset() }

        // 真正没数据时才补取，覆盖两种情形：刚进页面还没加载过就切环境，
        // 以及上一次加载失败了（这时切一下环境正好是自然的重试入口）。
        guard pipelineInfo == nil || loadErrorMessage != nil else { return }
        Task { await load() }
    }

    // MARK: - 代码分支

    /// 获取代码分支：流水线 → 仓库地址 → 仓库列表 → `repositoryId` → 分支列表。
    ///
    /// 链路里**没有一步是常量**：仓库地址来自流水线配置，
    /// `repositoryId` 来自仓库列表里匹配到的那一项，分支名全部来自接口。
    ///
    /// 失败时只写 `branchError`，不动 `state` —— 拿不到分支列表不该让
    /// "打包页加载失败"，用户仍然可以看到历史记录，也可以点重试。
    func loadBranches() async {
        isLoadingBranches = true
        branchError = nil
        defer { isLoadingBranches = false }

        do {
            branches = try await fetchBranches()
            selectedBranch = Self.defaultBranchSelection(
                branches: branches,
                sourceBranch: pipelineInfo?.sourceBranch,
                currentSelection: selectedBranch
            )
        } catch is CancellationError {
            // 页面切走 / 重新加载导致的取消不是错误，保持原有列表。
        } catch {
            branches = []
            selectedBranch = nil
            branchError = Self.message(for: error)
        }
    }

    /// 真正的取数过程。
    private func fetchBranches() async throws -> [CodeupBranch] {
        // 仓库地址只能从流水线详情拿到。`pipelineInfo` 可能因为上一个接口失败
        // 而为空，这时补拉一次 —— 用户点"刷新"时不该因为页面初始化失败就再也取不到。
        let info: PipelineInfo
        if let existing = pipelineInfo {
            info = existing
        } else {
            info = try await flowService.fetchPipelineInfo(environment: environment)
            pipelineInfo = info
        }

        // 「没有代码源」与「有代码源但没有地址」是两种不同的故障，分开报。
        guard !info.sources.isEmpty else { throw CodeupServiceError.pipelineHasNoSource }
        guard let repoURL = info.repoURL else { throw CodeupServiceError.pipelineSourceHasNoRepository }

        let repositories = try await codeupService.getRepositories()
        guard !repositories.isEmpty else { throw CodeupServiceError.emptyRepositoryList }

        guard let repository = RepositoryMatcher.match(
            pipelineRepo: repoURL,
            repositories: repositories
        ) else {
            // ⚠️ 只报数量，不打印仓库地址：那是私有资源，不该留在日志/截图里。
            throw CodeupServiceError.repositoryNotFound(repositoryCount: repositories.count)
        }

        let branches = try await codeupService.getBranches(repositoryId: repository.id)
        return Self.sortedBranches(branches)
    }

    /// 分支排序：默认分支排最前，其余按名字升序。
    ///
    /// 不假设默认分支叫 `test` —— 它叫什么完全由仓库决定，
    /// 只能按 `defaultBranch` 这个标记判断。
    static func sortedBranches(_ branches: [CodeupBranch]) -> [CodeupBranch] {
        branches.sorted { lhs, rhs in
            if lhs.defaultBranch != rhs.defaultBranch { return lhs.defaultBranch }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 初始选中项，按优先级取第一个可用的：
    /// 1. 流水线配置里保存的分支 —— **但必须确实存在于分支列表里**
    ///    （配置是过去的快照，那个分支可能已经被删了）
    /// 2. 仓库的默认分支
    /// 3. 列表里的第一个
    ///
    /// 保留用户当前的选择（刷新时不该把用户选好的分支重置掉）。
    static func defaultBranchSelection(
        branches: [CodeupBranch],
        sourceBranch: String?,
        currentSelection: String?
    ) -> String? {
        let names = Set(branches.map(\.name))
        if let currentSelection, names.contains(currentSelection) { return currentSelection }
        if let sourceBranch, names.contains(sourceBranch) { return sourceBranch }
        if let fallback = branches.first(where: \.defaultBranch) { return fallback.name }
        return branches.first?.name
    }

    // MARK: - 动作

    /// 开始打包。
    func startBuild() {
        task?.cancel()
        // 上一轮的结果就此作废：界面上不该在"正在触发"的时候还挂着上一次
        // 那个 APK 地址。这与 `state = .triggering` 是同一件事的两半 ——
        // 一边清掉流程状态，一边清掉"看哪一次运行"。
        currentBuildRun = nil
        state = .triggering
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch is CancellationError {
                // 用户主动取消或重新开始：回到空闲态，不当作失败。
                self.state = .idle
            } catch {
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    /// 取消正在进行的轮询。
    func cancel() {
        task?.cancel()
        task = nil
        currentBuildRun = nil
        state = .idle
    }

    /// 复位到初始状态。
    func reset() {
        task?.cancel()
        task = nil
        currentBuildRun = nil
        state = .idle
    }

    // MARK: - 流程

    private func run() async throws {
        // 分支必须先确实选出来。**不做任何默认值兜底** ——
        // 退回一个默认分支的表现是"用户选了 A、构建了 B"，而界面上一路显示
        // "构建成功"，比直接报错难查得多。界面上"开始打包"在分支为空时
        // 已经是禁用的，这里是第二道闸：从别的入口（快捷键、将来的自动化）
        // 触发时同样拦得住。
        guard let branch = selectedBranch else {
            throw FlowServiceError.missingBranchSelection
        }

        // API 4：触发运行，拿到**本次**的 pipelineRunId。
        //
        // 分支与环境在请求体里落在两个不同位置（`runningBranchs` / `envs`），
        // 所以这里必须把**两个**选择都传下去 —— 只传环境会静默地按默认分支构建。
        // 分支传的是用户选中的那个字符串本身（`release/release-20260922` 这类
        // 带斜杠的真实分支名也照样传），不做任何加工。
        //
        // 环境先取成局部常量再传：下面 `CurrentBuildRun` 要存的身份里，
        // `pipelineId` 必须是**这一次请求实际打到的那条流水线**，而不是
        // "之后某刻界面上的选择"。两次各读一遍 `self.environment` 也能编译、
        // 也几乎总是相等，但那样存下来的身份就可能与这一次运行真正跑的地方
        // 对不上 —— 而它决定去问哪条流水线的产物。
        //
        // `pipelineId` 由 `runPipeline` 自己回传（就是它拼进 POST 路径的那个
        // 局部变量），这里**不重新解析一遍**：详见 `PipelineRunTriggerResult`。
        let environment = self.environment
        let triggerResult = try await flowService.runPipeline(
            branch: branch,
            environment: environment
        )
        try Task.checkCancellation()
        state = .running(pipelineRunId: triggerResult.pipelineRunId, serverStatus: nil)

        // ⚠️ **触发一成功、拿到 ID 就立刻记下来，不等整条流程走完。**
        // 从这一刻起服务端上这一次运行就已经存在了，界面（本轮起由
        // `BuildResultView` 负责）也就能去问它的结果 —— 包括"还在跑"这件事本身。
        // 后面无论走到 FAIL / CANCELED 还是超时，它都是一次**真实**的运行。
        //
        // 先落成一个局部常量再用它：下面轮询与取结果问的都是**同一个**身份，
        // 不是各自再从当前状态里推导一遍。
        let identity = CurrentBuildRun(
            pipelineRunId: triggerResult.pipelineRunId,
            pipelineId: triggerResult.pipelineId
        )
        currentBuildRun = identity

        // 运行刚创建出来，先刷新一次历史，让它带着 RUNNING 出现在列表最上面。
        await refreshHistory()
        try Task.checkCancellation()

        // API 5：轮询到终态。
        let run = try await poll(identity)
        switch run.runStatus {
        case .succeeded:
            break
        case .failed:
            throw FlowServiceError.pipelineFailed("服务端返回状态 FAIL，请到 Yunxiao 控制台查看日志。")
        case .canceled:
            throw FlowServiceError.pipelineFailed(
                "本次运行被取消（状态 CANCELED）。通常是运行尚未结束就再次触发了流水线。"
            )
        case .running, .unknown:
            // 只有超时才会走到这里（`poll` 内部已把非终态循环到头）。
            throw FlowServiceError.pollingTimedOut(AppConfiguration.Polling.timeout)
        }

        state = .fetchingResult

        // API 6 / API 7：一次调用取回本次运行的全部结果。
        //
        // ⚠️ 传入的是「哪条流水线上的哪一次运行」这两个 ID —— 它们就是
        // `currentBuildRun` 里存的那一份身份。`jobId` / `stepIndex` / `buildId`
        // 是 Yunxiao 接口的内部细节，全部留在 `BuildService` 下面 ——
        // 「APK / 二维码怎么找」整个 App 只有那一处负责。
        let result = try await buildService.fetchBuildResult(
            pipelineRunId: identity.pipelineRunId,
            pipelineId: identity.pipelineId
        )

        // 服务端原文确实是 SUCCESS，但日志里可能一个产物标记都没有；
        // `BuildResult.artifacts` 那时是空的，界面会提示"构建成功，但没有找到
        // APK/二维码地址"。这仍然是成功态 —— 判成失败会误导用户去重跑一次
        // 已经跑成功的构建（详见 `BuildState.success` 的注释）。
        state = .success(result.artifacts)

        // 本次运行已经结束，刷新历史记录让它以终态出现在列表里。
        await refreshHistory()
    }

    /// 轮询运行状态直到终态。返回最后一次查到的整条运行记录。
    ///
    /// 返回 `PipelineRun` 而不是状态枚举，是为了让界面能展示服务端**原文**
    /// （`RUNNING`…）—— 归类成枚举之后就只剩"正在执行"这类客户端自己的措辞，
    /// 用户没法确认服务端到底回了什么。
    ///
    /// - Parameter identity: 本次运行的身份（**哪条流水线上的哪一次运行**）。
    ///   ⚠️ 轮询期间**必须一直问这一个身份**，不能从当前界面上的环境选择器
    ///   重新推导 `pipelineId` —— 用户在打包过程中切换环境时，那样做会让
    ///   后面的每一次查询都打到**另一条流水线**上，拿回来的运行详情与
    ///   本次运行对不上，而界面上看起来一切正常。
    private func poll(_ identity: CurrentBuildRun) async throws -> PipelineRun {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: AppConfiguration.Polling.timeout)

        // 触发接口刚刚返回，服务端那边这一轮运行可能还没落定。
        // 先等一拍再开始查询，避免一上来就问到一个中间状态。
        try await Task.sleep(for: AppConfiguration.Polling.initialDelay)

        while true {
            try Task.checkCancellation()

            let run = try await flowService.fetchRunStatus(
                pipelineId: identity.pipelineId,
                pipelineRunId: identity.pipelineRunId
            )
            // 原文照搬进状态里 —— 这就是界面上那个「服务端状态：RUNNING」的来源。
            state = .running(
                pipelineRunId: identity.pipelineRunId,
                serverStatus: run.status
            )

            if run.runStatus.isTerminal { return run }
            if clock.now >= deadline { return run }

            try await Task.sleep(for: AppConfiguration.Polling.interval)
        }
    }

    // MARK: - 辅助

    private static func message(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
