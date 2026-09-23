import Foundation

/// 一个 Job 下的构建步骤。
///
/// 接口：`GET …/pipelineRuns/{pipelineRunId}/jobs/{jobId}/steps`
/// ```json
/// [
///   {
///     "buildId": 7000001,
///     "jobId": 7000001,
///     "actionCode": "EXECUTION_COMPONENT_BUILD",
///     "actionName": "构建",
///     "startTime": "2026-09-22 11:12:29.0",
///     "buildProcessNodes": [
///       { "nodeName": "执行命令", "status": "running", "stepName": "执行命令", "stepIndex": 4 }
///     ]
///   }
/// ]
/// ```
///
/// `jobId` 与 `buildId` **不是同一个概念**，只是本次响应里数值恰好相同 ——
/// 因此两个字段各自建模，不互相替代。
struct PipelineStep: Sendable, Equatable, Decodable {

    let buildId: Int
    let jobId: Int
    let actionCode: String?
    let actionName: String?
    /// 该 action 下的步骤节点。
    let buildProcessNodes: [BuildProcessNode]?

    /// 本次响应里实际出现的步骤名，按 `stepIndex` 排序、已去重。
    ///
    /// 只用于**报错文案**：万一将来服务端又改了命名规则，错误信息里就直接带着
    /// 真实节点名，不必再远程调试一轮。节点名是业务数据，不含 Token / Header / 响应体。
    var stepNames: [String] {
        let names = (buildProcessNodes ?? []).compactMap(\.displayName)
        return names.reduce(into: [String]()) { unique, name in
            if !unique.contains(name) { unique.append(name) }
        }
    }

    /// 是否包含指定名字的步骤。
    func hasStep(named name: String) -> Bool {
        step(named: name) != nil
    }

    /// 按名字取步骤序号。
    ///
    /// 优先按 `stepName` 匹配；节点没有 `stepName` 时退回 `nodeName`。
    /// **不依赖 `stepIndex == 4`** —— 步骤顺序将来可能变化。
    func stepIndex(named name: String) -> Int {
        step(named: name)?.stepIndex ?? 0
    }

    private func step(named name: String) -> BuildProcessNode? {
        buildProcessNodes?.first { $0.matches(named: name) }
    }
}

/// 步骤节点。
struct BuildProcessNode: Sendable, Equatable, Decodable {
    let nodeName: String?
    let stepName: String?
    let stepIndex: Int
    let status: String?

    /// 用于展示 / 报错的原文名字，`stepName` 优先。
    var displayName: String? { stepName ?? nodeName }

    /// 名字是否与给定名字指向同一步骤。
    ///
    /// ⚠️ **不能拿原文精确相等去比。** 服务端在步骤跑完后会把显示名改写成
    /// 「名字(耗时)」——运行中的 `执行命令` 跑完后是 `执行命令(331s)`，
    /// `stepName` 与 `nodeName` **一起**被改写。
    ///
    /// 而客户端是等运行到了终态才来取 steps 的，也就是说它**永远**只见到带后缀的
    /// 那一份；按原文比必然落空，表现成
    /// 「未找到 stepName 为『执行命令』的步骤」。
    ///
    /// 所以两侧都先归一化再比。**只做归一化后的相等，不做前缀 / 包含匹配** ——
    /// 那是另一个步骤也可能命中的匹配方式（`执行命令` 会命中 `执行命令2`）。
    func matches(named name: String) -> Bool {
        if let stepName, Self.baseName(stepName) == name { return true }
        if let nodeName, Self.baseName(nodeName) == name { return true }
        return false
    }

    /// 剥掉结尾的耗时后缀：`"执行命令(331s)"` → `"执行命令"`。
    ///
    /// 名字中间的括号原样保留（`"打包(测试)(12s)"` → `"打包(测试)"`），
    /// 没有后缀的名字原样返回（`"执行命令"` → `"执行命令"`）。
    static func baseName(_ name: String) -> String {
        let range = NSRange(name.startIndex..., in: name)
        guard
            let match = durationSuffix.firstMatch(in: name, range: range),
            let matchRange = Range(match.range, in: name)
        else { return name }
        return String(name[name.startIndex..<matchRange.lowerBound])
    }

    /// 结尾的耗时，形如 `(331s)` / `(1m 30s)` / `(2h5m)`。
    ///
    /// 要求括号里**至少带一个时间单位字母**：纯粹的数字括号（`(2)`）不剥，
    /// 免得把「打包(2)」这种正经步骤名啃掉。
    private static let durationSuffix = try! NSRegularExpression(
        pattern: #"\(\s*(?:\d+\s*[hms]\s*)+\)$"#
    )
}
