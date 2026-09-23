import Foundation

/// 全局配置。
///
/// 这里只放**与具体组织无关**的常量：环境枚举、接口路径模板、日志标记、轮询参数。
/// 域名 / organizationId / pipelineId 依赖具体 Yunxiao 组织，放在 `BuildConfig`
/// 对应的本地配置文件里，不写死在源码中。
///
/// **本文件不允许出现任何 Token。**
enum AppConfiguration {

    /// 当前客户端支持的环境。APK 上传路径中的 `debug` 段与之对应。
    enum Environment: String, CaseIterable, Sendable, Identifiable, Codable {
        case test
        case release

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .test: "Test 环境"
            case .release: "Release 环境"
            }
        }
    }

    // ⚠️ 这里**没有**「代码分支」枚举，也不要再加回来。
    //
    // 分支不是一个可以穷举的客户端常量：它的取值范围由仓库决定，
    // 真实分支名可能是 `release/release-20250101` 这种带斜杠的形态，
    // 任何 `enum Branch { case test, release }` 都表达不出来。
    // 曾经有过这样一个枚举，后果是界面上选中的分支在触发时被丢掉、
    // 请求体里永远是默认的那一个 —— 而界面上一路显示"构建成功"。
    //
    // 分支值的唯一来源是 Codeup 分支接口 + 用户选择（`BuildViewModel.selectedBranch`），
    // 以 `String` 原样透传到请求体，不做大小写转换、不加前后缀。
    //
    // 与「构建环境」的区别：环境决定用哪条流水线，它是本地配置里的一个键，
    // 所以仍然是一个枚举。两者在请求体里落在不同位置：
    // ```
    // runningBranchs[<仓库地址>] = 分支（来自接口 + 用户选择）
    // envs["env"]               = 环境（来自本地配置）
    // ```

    // MARK: - 接口路径

    /// Yunxiao / Flow 接口路径模板。
    ///
    /// 路径全部来自已通过 Postman 实际验证的请求，不做任何推测性改动。
    /// `pipelineRunId` / `jobId` / `buildId` 这类每次构建都不同的值**只以参数形式出现**，
    /// 不允许写成常量。
    ///
    /// ⚠️ 两条路径族的前缀**不一样**，这不是笔误：
    /// 「运行详情」在 `/runs/{id}` 下，「Job / Step / 日志」在 `/pipelineRuns/{id}` 下。
    /// 用错任何一个都会直接 404，且错误信息看起来像"配置写错了"，很难倒查。
    /// 判定方式：无 Token 请求时，**路由存在返回 401、路由不存在返回 404**，
    /// 据此逐条确认过（见 `pipelineRun` / `pipelineRunJobs` 的注释）。
    enum Path {
        /// 当前用户信息。用于验证 Token。
        static let currentUser = "/oapi/v1/platform/user"

        /// 流水线详情。
        static func pipeline(organizationId: String, pipelineId: String) -> String {
            "/oapi/v1/flow/organizations/\(organizationId)/pipelines/\(pipelineId)"
        }

        /// 流水线历史运行记录 / 触发新的运行（同一路径，GET 与 POST）。
        static func pipelineRuns(organizationId: String, pipelineId: String) -> String {
            pipeline(organizationId: organizationId, pipelineId: pipelineId) + "/runs"
        }

        /// 单次运行详情。轮询状态与读取运行详情（取 `jobId`）都用它。
        ///
        /// 前缀是 `/runs`，**不是** `/pipelineRuns` ——
        /// 实测 `/runs/1` → 401（路由存在），`/pipelineRuns/1` → 404（无此路由）。
        static func pipelineRun(organizationId: String, pipelineId: String, pipelineRunId: String) -> String {
            pipelineRuns(organizationId: organizationId, pipelineId: pipelineId)
                + "/\(pipelineRunId)"
        }

        /// 单次运行下 Job 相关接口的前缀。
        ///
        /// 与 `pipelineRun` 相反，这一族用的是 `/pipelineRuns` ——
        /// 实测 `/pipelineRuns/1/jobs/1/steps` → 401（路由存在），
        /// 而 `/runs/1/jobs/1/steps` → 404（无此路由）。
        static func pipelineRunJobs(
            organizationId: String,
            pipelineId: String,
            pipelineRunId: String
        ) -> String {
            pipeline(organizationId: organizationId, pipelineId: pipelineId)
                + "/pipelineRuns/\(pipelineRunId)"
        }

        /// 单次运行下的执行步骤列表。
        static func steps(
            organizationId: String,
            pipelineId: String,
            pipelineRunId: String,
            jobId: String
        ) -> String {
            pipelineRunJobs(
                organizationId: organizationId,
                pipelineId: pipelineId,
                pipelineRunId: pipelineRunId
            ) + "/jobs/\(jobId)/steps"
        }

        /// 某个步骤的完整日志。
        static func stepLog(
            organizationId: String,
            pipelineId: String,
            pipelineRunId: String,
            jobId: String
        ) -> String {
            pipelineRunJobs(
                organizationId: organizationId,
                pipelineId: pipelineId,
                pipelineRunId: pipelineRunId
            ) + "/jobs/\(jobId)/step/log"
        }

        // MARK: Codeup（代码库与分支）

        /// 组织下的代码库列表。
        ///
        /// ⚠️ 这是**另一族前缀**：`/oapi/v1/codeup/...`，与上面 Flow 的
        /// `/oapi/v1/flow/...` 不是同一套。用错会直接 404，
        /// 而错误信息看起来像"Token 没权限"，会被带偏。
        ///
        /// `repositoryId` 只以参数形式出现在 `branches` 里，**不允许写死**。
        static func codeupRepositories(organizationId: String) -> String {
            "/oapi/v1/codeup/organizations/\(organizationId)/repositories"
        }

        /// 某个代码库的分支列表。
        static func codeupBranches(organizationId: String, repositoryId: String) -> String {
            codeupRepositories(organizationId: organizationId) + "/\(repositoryId)/branches"
        }
    }

    // MARK: - Codeup 分页

    /// Codeup 列表接口的分页参数。
    ///
    /// 两个列表接口（仓库 / 分支）都要**完整翻页**：一个页面不保证覆盖全部数据，
    /// 而"没翻到的那个仓库恰好就是流水线绑定的那个"这件事在界面上
    /// 表现为"找不到对应的仓库" —— 看起来像配置错了。
    enum CodeupPaging {
        /// 每页条数。取 100（接口允许的较大值），翻页次数因此最少。
        static let perPage = 100
        /// 起始页码。
        static let firstPage = 1
        /// 翻页上限。
        ///
        /// 真按响应头翻页时用不到它（`x-total-pages` 说停就停）；
        /// 它是**响应头缺失时**的兜底：那种情况下只能按"这一页取满了没有"
        /// 判断是否继续，而没有上限的循环一旦服务端总是返回满页就会停不下来。
        /// 100 页 × 100 条 = 10000 个仓库/分支，远超实际规模。
        static let maxPages = 100
        /// 响应头里的下一页页码。
        static let nextPageHeader = "x-next-page"
        /// 响应头里的总页数。
        static let totalPagesHeader = "x-total-pages"
        /// 响应头里的总条数。
        static let totalHeader = "x-total"
    }

    // MARK: - 结果解析

    /// 从日志里找产物标记时的重试节奏。
    ///
    /// 为什么需要重试：流水线状态已经是 `SUCCESS` 时，日志文件可能还有
    /// 最后一次刷盘没落定 —— 此刻读到的日志会缺掉末尾几行，而产物标记
    /// 恰恰就在末尾。立刻判定"没有产物"会把一次成功的构建说成异常。
    ///
    /// 为什么单独成一个类型而不是两个常量：这是「等待」类参数，
    /// 测试必须在毫秒级跑完，而生产要等够服务端刷盘。做成可注入的值，
    /// 而不是让测试去等真实的秒数（那会让每个用例慢几秒且不稳定）。
    struct ResultParsing: Sendable {

        /// 读取日志的**总尝试次数**（含第一次，不是"重试 3 次"）。
        ///
        /// 上限必须是有限的：标记若真的不存在（例如打包脚本改了输出格式），
        /// 重试多少次都不会出现，无限循环只会让界面永远转圈。
        var maxAttempts: Int

        /// 两次尝试之间的等待。上限 3 次即最多等 2 次。
        var delay: Duration

        /// 生产参数：最多 3 次，每次间隔 2 秒。
        static let standard = ResultParsing(maxAttempts: 3, delay: .seconds(2))
    }

    // MARK: - Step Log 读取参数

    /// 单次 Step Log 请求的读取上限。
    ///
    /// 已通过 Postman 验证 `offset=0&limit=10000` 可以取回完整 `logs`，
    /// 因此按整段读取处理，不按固定 offset / 固定行数分段（那些值每次都不同）。
    static let stepLogLimit = 10_000

    /// Step Log 的起始偏移。固定为 0，表示从头读取。
    static let stepLogOffset = 0

    // MARK: - 轮询

    enum Polling {
        /// 触发成功到**第一次**查询状态之间的等待。
        ///
        /// 刚 `POST /runs` 返回时，运行在服务端往往还没进入可查询状态；
        /// 立刻查会拿到一个没有意义的中间结果。先等一拍再开始轮询。
        static let initialDelay: Duration = .seconds(2)
        /// 两次状态查询之间的间隔。已确认按 2 秒轮询。
        static let interval: Duration = .seconds(2)
        /// 最长等待时间，超过则判定为超时。
        ///
        /// `Duration` 没有 `.minutes`，因此按秒表达（30 分钟）。
        static let timeout: Duration = .seconds(30 * 60)
    }

    // MARK: - 日志标记

    /// 日志解析所使用的标记。标记本身来自现有 Gradle 打包脚本的稳定输出。
    enum LogMarker {
        /// 例：`上传完成->https://<host>/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk`
        static let uploadCompleted = "上传完成->"

        /// 例：`二维码地址->https://<host>/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png`
        static let qrCodeAddress = "二维码地址->"
    }
}
