import Foundation

/// 一次运行的「头部」信息 —— 运行详情里与构建结果有关的那几项。
///
/// 与 `StepTarget` 分开是刻意的：状态和开始时间**不需要经过步骤列表**就能拿到，
/// 而状态不是成功时，后面的步骤定位与日志读取根本不该发生。
struct PipelineRunHead: Sendable, Equatable {
    /// 服务端返回的状态**原文**（`SUCCESS` / `FAIL` / `CANCELED`…）。
    let status: String
    /// 运行开始时间（毫秒时间戳）。接口没给就是 `nil`，不用本地时间兜底。
    ///
    /// ⚠️ 两条链路的字段名不同（详情接口给 `createTime`、历史接口给 `startTime`），
    /// 取值与兜底在 `fetchRunHead` 里做，这里只表达"最后拿到的那个时间"。
    let createdAt: Int64?
    /// 本次运行里「编译并构建上传」这个 Job 的 ID。
    ///
    /// **可选** —— 运行详情里可能根本没有 stages（失败 / 取消的运行常常如此），
    /// 那时它是 `nil`。这里不判"没找到就失败"：那次运行本来就不需要再去定位步骤，
    /// 判定与报错落在 `buildStepTarget` 里，只有确实要继续往下走时才撞得上。
    let jobID: Int?
}

/// 一次触发的返回值：新运行的 ID，以及**这次请求实际打到的那条流水线**。
///
/// ⚠️ **为什么 `pipelineId` 必须由触发调用自己带出来。**
///
/// 触发接口的响应体只有一个裸数字（本次 `pipelineRunId`），里面**没有** `pipelineId`。
/// `pipelineId` 是 `runPipeline` 从本地配置解析出来、放进 POST 路径的那个值。
/// 只有发起这次请求的这一层知道它到底打到了哪条流水线 —— 让调用方自己再解析一遍
/// （`BuildViewModel` 读一次 `BuildConfig`，`runPipeline` 再读一次）会得到两个
/// 各自独立解析出来的值：它们几乎总是相等，但**没有任何机制保证相等**。
/// 一旦不等，用户看到的就是"另一条流水线的运行结果"，而且完全看不出异常。
///
/// 所以这里回传的是**确实进了 URL 的那一个变量**，不是"重新解析出来的那一个"。
struct PipelineRunTriggerResult: Sendable, Equatable {
    /// 本次运行的 ID。来自触发接口的响应体。
    let pipelineRunId: Int
    /// 这次触发请求**实际使用**的流水线 ID。**不是**服务端返回的字段。
    let pipelineId: String
}

/// 一次运行的 Job / Step 定位信息。
///
/// 这条链路是第二阶段的核心，每一环都从接口响应里动态取得：
/// ```
/// pipelineRunId → jobId → buildId → stepIndex → 日志
/// ```
/// 因此这里**没有任何一个字段是常量**。
///
/// ⚠️ 这是 **`BuildService` 内部**的定位结果，不是上层的概念 ——
/// 它不出现在 `FlowServiceProtocol` 上，`BuildViewModel` / View 都不该见到它。
struct StepTarget: Sendable, Equatable {
    /// 本次运行里「编译并构建上传」这个 Job 的 ID。
    let jobID: Int
    /// 「执行命令」步骤的序号。按 `stepName` 找到，不写死 4。
    let stepIndex: Int
    /// 该步骤对应的构建 ID。
    let buildID: Int
}

/// 流水线能力抽象。
///
/// ⚠️ **两类查询用的是两种不同的键，这不是不一致，是刻意的。**
///
/// - **环境级查询**用 `environment`：「这个环境对应的流水线长什么样」。
///   环境是它的自然键，配置里就是这么索引的。
/// - **具体 Run 查询**用 `pipelineId + pipelineRunId`：「**这一条**运行的结果是什么」。
///
/// 后者为什么不能用 `environment`：一次运行一旦建立，它属于哪条流水线就已经是
/// 既成事实，不该再由"此刻界面上选的是哪个环境"重新推导。运行期间用户切换环境、
/// 或者将来两个环境指向不同流水线时，用环境去查这条运行会打到**另一条流水线**上，
/// 拿到一条 ID 恰好相同、或干脆不存在的运行 —— 前者是静默取错数据。
protocol FlowServiceProtocol: Sendable {

    /// 查询流水线基本信息。
    func fetchPipelineInfo(
        environment: AppConfiguration.Environment
    ) async throws -> PipelineInfo

    /// 查询历史运行记录。
    func fetchPipelineRuns(
        environment: AppConfiguration.Environment
    ) async throws -> [PipelineRun]

    /// 触发一次打包。
    ///
    /// 返回的不只是 `pipelineRunId`，还有**这次请求实际使用的那条流水线 ID** ——
    /// 调用方要凭这两个值把"当前这次构建"记下来，之后所有针对它的查询都用它们。
    /// 详见 `PipelineRunTriggerResult`。
    ///
    /// - Parameters:
    ///   - branch: 代码分支名，**原样**作为 `runningBranchs` 的取值发出去。
    ///     类型是 `String` 而不是某个本地枚举：分支的取值范围由仓库决定
    ///     （真实分支名可能是 `release/release-20250101` 这种带斜杠的形态），
    ///     客户端枚举表达不出来，只能原样透传接口 + 用户选择给出的字符串。
    ///     与 `environment` 是两个**独立**参数。
    ///   - environment: 构建环境（决定用哪条流水线，所以是本地枚举）。
    func runPipeline(
        branch: String,
        environment: AppConfiguration.Environment
    ) async throws -> PipelineRunTriggerResult

    /// 查询单次运行的当前状态。
    ///
    /// 返回整条 `PipelineRun` 而不是只返回一个状态枚举：轮询期间界面要展示
    /// **服务端原文**（`RUNNING`…），这只有原文才给得出。
    func fetchRunStatus(
        pipelineId: String,
        pipelineRunId: Int
    ) async throws -> PipelineRun

    /// 取本次运行的头部信息：状态原文、开始时间，以及打包 Job 的 ID。
    ///
    /// ⚠️ **这两个方法在协议上，但不在"上层理解的链路"里。**
    /// `fetchStepLog` 需要的 `StepTarget` 不在协议上（它是 `BuildService` 的内部概念），
    /// 所以由 `buildStepTarget(...)` 在服务内部把 Job 名 → jobId →「执行命令」步骤
    /// 这一段补全。上层只需要 `BuildServiceProtocol`。
    func fetchRunHead(
        pipelineId: String,
        pipelineRunId: Int
    ) async throws -> PipelineRunHead

    /// 按「Job 名 → jobId → 步骤名 → stepIndex / buildId」定位打包步骤。
    ///
    /// `jobID` 是**可选**的，与 `PipelineRunDetail.jobID(named:)` 的返回类型一致：
    /// 运行详情里没有 stages（失败 / 取消的运行常常如此）时它就是 `nil`，
    /// 由本方法抛出带上下文的错误，而不是在 `fetchRunHead` 里提前炸掉 ——
    /// 那种运行本来就不会走到这一步。
    func buildStepTarget(
        pipelineId: String,
        pipelineRunId: Int,
        jobID: Int?
    ) async throws -> StepTarget

    /// 读取某个步骤的完整日志。
    func fetchStepLog(
        pipelineId: String,
        pipelineRunId: Int,
        target: StepTarget
    ) async throws -> String
}

// MARK: - 真实实现

/// 真实实现：只负责拼路径、做字段映射，所有 HTTP 细节交给 `APIClient`。
struct FlowService: FlowServiceProtocol {

    /// Job 名。本次运行的 Job 从这个名字定位 —— 真实值，不是猜测。
    static let buildJobName = "编译并构建上传"

    /// 打包步骤名。步骤序号按名字查，避免依赖 `stepIndex == 4`。
    static let buildStepName = "执行命令"

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

    // MARK: 配置

    /// 读取本地配置，并取出某个环境的流水线 ID。
    ///
    /// ⚠️ **只有环境级查询才用它**（流水线详情 / 历史记录 / 触发）。
    /// 具体 Run 的查询拿到的已经是 `pipelineId` 本身，不该再回到这里反查 ——
    /// 那等于把已经确定的身份重新交给"当前环境"去推导一遍。
    private func context(
        for environment: AppConfiguration.Environment
    ) throws -> (config: BuildConfig, pipelineID: String) {
        let config = try configProvider()
        guard let pipelineID = config.pipelineID(for: environment) else {
            throw FlowServiceError.configurationMissing("pipelines.\(environment.rawValue)")
        }
        return (config, pipelineID)
    }

    /// 具体 Run 查询只需要配置里的组织 ID —— 流水线 ID 由调用方直接给出。
    private func organizationId() throws -> String {
        try configProvider().organizationId
    }

    // MARK: API 2 —— 流水线详情

    func fetchPipelineInfo(
        environment: AppConfiguration.Environment
    ) async throws -> PipelineInfo {
        let (config, pipelineID) = try context(for: environment)
        return try await pipelineInfo(config: config, pipelineID: pipelineID)
    }

    /// 取流水线详情的实际请求。触发打包也要用它 —— 仓库地址只能从这里拿到。
    private func pipelineInfo(
        config: BuildConfig,
        pipelineID: String
    ) async throws -> PipelineInfo {
        let request = try URLRequest.yunxiao(
            path: AppConfiguration.Path.pipeline(
                organizationId: config.organizationId,
                pipelineId: pipelineID
            ),
            method: "GET"
        )
        return try await api.send(request, decoding: PipelineInfo.self)
    }

    // MARK: API 3 —— 历史运行记录

    /// 历史记录接口返回的就是**裸数组**，直接整体解码。
    /// 不做分页 —— 已确认当前不需要。
    func fetchPipelineRuns(
        environment: AppConfiguration.Environment
    ) async throws -> [PipelineRun] {
        let (config, pipelineID) = try context(for: environment)
        let request = try URLRequest.yunxiao(
            path: AppConfiguration.Path.pipelineRuns(
                organizationId: config.organizationId,
                pipelineId: pipelineID
            ),
            method: "GET"
        )
        return try await api.send(request, decoding: [PipelineRun].self)
    }

    // MARK: API 4 —— 触发运行

    /// 触发运行。
    ///
    /// 请求体形状（已通过实际请求验证）：
    /// ```json
    /// { "params": "{\"runningBranchs\":{\"<仓库地址>\":\"<分支>\"},\"envs\":{\"env\":\"<环境>\"}}" }
    /// ```
    ///
    /// ⚠️ **`params` 的值是一段 JSON 字符串，不是一个 JSON 对象。**
    /// 也就是说它要**被转义后再嵌进外层 JSON**。直接传对象服务端会拒收，
    /// 而错误信息看起来像参数写错了，不会指向"嵌套层级不对"。
    ///
    /// ⚠️ `runningBranchs` 的键是**仓库地址**，只能从流水线详情的
    /// `pipelineConfig.sources[].data.repo` 读出来，**不允许写死**。
    /// 因此触发前必须先取一次流水线详情；拿不到地址就明确报错，不退回
    /// "发一个不带 body 的请求"——那样会静默地按流水线默认分支构建，
    /// 用户以为选了分支、实际没选。
    ///
    /// ⚠️ 成功的响应体就是**本次 `pipelineRunId` 的裸数字**（例如 `30`），
    /// 外面没有对象包装、也不是字符串。
    /// 因此这里直接解码成一个 `Int`，而不是"拉历史记录猜哪个是最新的"。
    ///
    /// 若服务端将来改成 `{"pipelineRunId":30}` 这类结构，解码会失败并抛出
    /// `APIError.decodingFailed`，错误信息会写明"响应根节点类型不匹配，期望 Int" ——
    /// 也就是说这里一旦变形，表现是**解析失败**，而不是静默拿到错的 ID。
    ///
    /// ⚠️ 返回的 `pipelineId` 是下面**实际拼进 POST 路径的那个局部变量**
    /// （`let (config, pipelineID) = try context(for: environment)`），
    /// 不是重新解析一次得到的值 —— 详见 `PipelineRunTriggerResult`。
    ///
    /// - Parameter branch: 分支名**原样**进入请求体，这里不做任何加工 ——
    ///   远端就是因为"触发时丢掉了用户选的分支"才修的这处。
    func runPipeline(
        branch: String,
        environment: AppConfiguration.Environment
    ) async throws -> PipelineRunTriggerResult {
        let (config, pipelineID) = try context(for: environment)

        // 仓库地址是触发体的键，只能从流水线配置里取。
        let info = try await pipelineInfo(config: config, pipelineID: pipelineID)
        guard let repoURL = info.repoURL else {
            throw FlowServiceError.missingIdentifier(
                "本次触发的仓库地址（在 pipelineConfig.sources[].data.repo 中未找到代码源仓库地址，"
                    + "无法确定 runningBranchs 的键）"
            )
        }

        let body = try TriggerParameters.encode(
            repoURL: repoURL,
            branch: branch,
            environment: environment.rawValue
        )

        let request = try URLRequest.yunxiao(
            path: AppConfiguration.Path.pipelineRuns(
                organizationId: config.organizationId,
                pipelineId: pipelineID
            ),
            method: "POST",
            body: body
        )
        let pipelineRunId = try await api.send(request, decoding: Int.self)

        // 这一层断言是**动态取 ID 这条约束的守门人**：
        // 只有拿到的确实是一个新 ID，后面的轮询 / 取 Job / 取日志才有意义。
        guard pipelineRunId > 0 else {
            throw FlowServiceError.invalidPipelineRunID(pipelineRunId)
        }
        return PipelineRunTriggerResult(
            pipelineRunId: pipelineRunId,
            pipelineId: pipelineID
        )
    }

    // MARK: API 5 —— 运行状态

    func fetchRunStatus(
        pipelineId: String,
        pipelineRunId: Int
    ) async throws -> PipelineRun {
        let request = try URLRequest.yunxiao(
            path: AppConfiguration.Path.pipelineRun(
                organizationId: try organizationId(),
                pipelineId: pipelineId,
                pipelineRunId: String(pipelineRunId)
            ),
            method: "GET"
        )
        return try await api.send(request, decoding: PipelineRun.self)
    }

    // MARK: API 6 —— 运行头部 与 Job / Step / Build

    /// 取运行头部：状态原文、开始时间，以及打包 Job 的 ID。
    ///
    /// `jobId` 来自运行详情里 `stages → stageInfo → jobs` 中
    /// `name == "\(buildJobName)"` 的那一项。
    ///
    /// ⚠️ `jobID` 是**可选**的，这里不在这里判"没找到就报错"：
    /// 一次被取消或失败的运行可能根本没有 stages，而那种运行本来就不需要
    /// 再去定位步骤。判定与报错落在 `buildStepTarget` 里，
    /// 只有确实要继续往下走的时候才会撞上它。
    func fetchRunHead(
        pipelineId: String,
        pipelineRunId: Int
    ) async throws -> PipelineRunHead {
        let request = try URLRequest.yunxiao(
            path: AppConfiguration.Path.pipelineRun(
                organizationId: try organizationId(),
                pipelineId: pipelineId,
                pipelineRunId: String(pipelineRunId)
            ),
            method: "GET"
        )
        let detail = try await api.send(request, decoding: PipelineRunDetail.self)

        return PipelineRunHead(
            status: detail.status,
            // ⚠️ 两个字段是**两条链路上同一个事实的不同叫法**，不是两个事实。
            // 这个端点（`/runs/{id}`）实测给的是 `createTime`，**没有** `startTime`；
            // 历史记录接口（`/runs`）恰好相反。以前只读 `startTime`，在这个端点上
            // 恒为 `nil` —— 于是界面上的「构建时间」永远是一个占位符
            // （`BuildResultView.infoSection` 那行 `dateText(nil)` → `—`），
            // 而历史列表里同一时刻却显示得好好的，看起来像是结果页坏了。
            //
            // 先 `startTime` 后 `createTime`：两个都有时以历史接口那个名字为准，
            // 与历史列表里的取值保持一致。两个都没有仍然是 `nil`，
            // **不用本地时间兜底**（见 `PipelineRunHead.createdAt` 的注释）。
            createdAt: detail.startTime ?? detail.createTime,
            jobID: detail.jobID(named: Self.buildJobName)
        )
    }

    /// 取该 Job 的步骤列表，定位出打包步骤的 `stepIndex` 与 `buildId`。
    ///
    /// `buildId` / `stepIndex` 来自步骤列表里
    /// `stepName == "\(buildStepName)"` 的那一项（跑完后名字会带耗时后缀，
    /// 归一化匹配在 `PipelineStep` 里做）。
    ///
    /// - Parameter jobID: 来自 `fetchRunHead`。为 `nil` 表示运行详情里
    ///   没有那个 Job —— 这时明确报错，不退化成"取第一个 Job"。
    func buildStepTarget(
        pipelineId: String,
        pipelineRunId: Int,
        jobID: Int?
    ) async throws -> StepTarget {
        guard let jobID else {
            throw FlowServiceError.missingIdentifier(
                "本次运行的 jobId（在 stages → stageInfo → jobs 中未找到 name 为「\(Self.buildJobName)」的 Job）"
            )
        }

        let stepsRequest = try URLRequest.yunxiao(
            path: AppConfiguration.Path.steps(
                organizationId: try organizationId(),
                pipelineId: pipelineId,
                pipelineRunId: String(pipelineRunId),
                jobId: String(jobID)
            ),
            method: "GET"
        )
        let steps = try await api.send(stepsRequest, decoding: [PipelineStep].self)

        guard let step = steps.first(where: { $0.hasStep(named: Self.buildStepName) }) else {
            throw FlowServiceError.missingIdentifier(
                Self.missingStepDetail(in: steps)
            )
        }

        return StepTarget(
            jobID: jobID,
            stepIndex: step.stepIndex(named: Self.buildStepName),
            buildID: step.buildId
        )
    }

    /// 「没找到打包步骤」时的报错文案。
    ///
    /// 把本次响应里**实际出现的**步骤名一起写进去：这类失败的排查成本几乎全在
    /// "服务端到底给的是什么名字"上，而节点名本来就是接口里允许展示的业务数据
    /// （不含 Token / Header / 响应体）。
    ///
    /// 为什么值得为它写一个函数：上一轮线上故障正是栽在名字上 ——
    /// 服务端在步骤跑完后会把显示名从 `执行命令` 改写成 `执行命令(331s)`，
    /// 而客户端只在终态才来取 steps，于是永远匹配不上。
    /// 下次服务端若再动命名，截图里就带着真实节点名，不必再远程调试一轮。
    private static func missingStepDetail(in steps: [PipelineStep]) -> String {
        let names = steps.flatMap(\.stepNames)
        guard !names.isEmpty else {
            // 连节点都没有：退化为原本文案，附上"响应里一个节点都没有"这个事实。
            return "本次 stepIndex（步骤列表中未找到名称为「\(buildStepName)」的步骤；"
                + "本次响应里没有任何步骤节点）"
        }
        return "本次 stepIndex（步骤列表中未找到名称为「\(buildStepName)」的步骤；"
            + "本次响应中的步骤为：\(names.joined(separator: " | "))）"
    }

    // MARK: API 7 —— 步骤日志

    /// 读取「执行命令」步骤的完整日志。
    ///
    /// 固定 `offset=0&limit=10000` 整段读取，不计算"最后 N 行" ——
    /// 日志将来变长也不影响，因为解析只看标记，不看位置。
    func fetchStepLog(
        pipelineId: String,
        pipelineRunId: Int,
        target: StepTarget
    ) async throws -> String {
        let path = AppConfiguration.Path.stepLog(
            organizationId: try organizationId(),
            pipelineId: pipelineId,
            pipelineRunId: String(pipelineRunId),
            jobId: String(target.jobID)
        )
        let query = [
            URLQueryItem(name: "stepIndex", value: String(target.stepIndex)),
            URLQueryItem(name: "offset", value: String(AppConfiguration.stepLogOffset)),
            URLQueryItem(name: "limit", value: String(AppConfiguration.stepLogLimit)),
            URLQueryItem(name: "buildId", value: String(target.buildID)),
        ]

        let request = try URLRequest.yunxiao(path: path, method: "GET", query: query)
        let log = try await api.send(request, decoding: StepLog.self)
        return log.logs
    }
}

// MARK: - 触发参数

/// 触发流水线时提交的 `params`。
///
/// 单独成一个类型（而不是在 `runPipeline` 里手拼字符串）的理由：
/// 这里是**唯一**一处把用户选择翻译成服务端参数的地方，
/// 拼错了不会编译失败、只会静默地构建另一个分支 —— 所以它必须能被单独断言。
///
/// 目标形状：
/// ```json
/// { "runningBranchs": { "<仓库地址>": "<分支>" }, "envs": { "env": "<环境>" } }
/// ```
/// 而它整体要作为**一个 JSON 字符串**塞进外层 `{"params": "…"}`，
/// 因此这里先把内层序列化成字符串，再交给外层编码器转义。
///
/// ⚠️ **不要用 `[String: String]` 之类的字典直接编码内层。**
/// Swift 字典的键序是不确定的，两次相同输入可能产出**字节不同**的请求体，
/// 测试里就无法对请求体做稳定断言。这里用 `Codable` 结构体，
/// 键序由属性声明顺序固定下来。
struct TriggerParameters: Sendable, Equatable, Encodable {

    /// 仓库地址 → 分支。**分支由用户选择，仓库地址取自流水线配置。**
    let runningBranchs: [String: String]
    /// 环境。服务端约定这个对象只有一个 `env` 键。
    let envs: [String: String]

    /// 内层参数的 JSON 文本（未转义）。用于断言与排查，不含任何敏感信息。
    var paramsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8)
        else {
            // 两个 `[String: String]` 编码不可能失败；真失败了也绝不能把
            // 半成品请求体发出去，所以这里崩掉比静默发一个错的强。
            preconditionFailure("触发参数编码失败")
        }
        return json
    }

    /// 外层请求体：`{"params": "<被转义的 JSON 字符串>"}`。
    static func encode(repoURL: String, branch: String, environment: String) throws -> Data {
        let parameters = TriggerParameters(
            runningBranchs: [repoURL: branch],
            envs: ["env": environment]
        )
        return try JSONEncoder().encode(Envelope(params: parameters.paramsJSON))
    }

    /// 外层包装。`params` 是**字符串**，不是对象 —— 这一点不能"顺手优化"掉。
    private struct Envelope: Encodable {
        let params: String
    }
}
