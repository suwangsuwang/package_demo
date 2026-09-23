import Foundation

/// 本地构建配置：域名、组织 ID、各环境对应的流水线 ID。
///
/// 这些值依赖具体的 Yunxiao 组织，**不入库**，因此放在一个被 `.gitignore` 忽略的
/// `buildconfig.local.json` 里，而不是写死在源码里。
///
/// 查找顺序（取第一个存在的）：
/// 1. 环境变量 `ANDROID_BUILD_CLIENT_CONFIG` 指向的文件
/// 2. `~/Library/Application Support/AndroidBuildClient/buildconfig.json`
/// 3. 当前工作目录起向上最多 5 级目录中的 `buildconfig.local.json`
///    —— 覆盖"在仓库根目录启动 App / 从 Xcode 运行"的常见情况
///
/// 文件内容示例（见仓库根目录的 `buildconfig.example.json`）：
/// ```json
/// {
///   "yunxiaoDomain": "https://openapi-rdc.aliyuncs.com",
///   "organizationId": "你的组织 ID",
///   "pipelines": { "test": "Test 环境流水线 ID" }
/// }
/// ```
///
/// 注意：**Token 不在这里**。Token 只进 Keychain。
struct BuildConfig: Sendable, Equatable, Decodable {

    /// Yunxiao 域名，例如 `https://openapi-rdc.aliyuncs.com`。
    let yunxiaoDomain: String
    /// 组织 ID。
    let organizationId: String
    /// 环境 → 流水线 ID。键为 `AppConfiguration.Environment.rawValue`。
    let pipelines: [String: String]

    /// 取某个环境对应的流水线 ID。
    func pipelineID(for environment: AppConfiguration.Environment) -> String? {
        let value = pipelines[environment.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 域名解析成 `URL`。
    var domainURL: URL? {
        URL(string: yunxiaoDomain.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 配置是否完整到可以发起真实请求。
    var missingFields: [String] {
        var missing: [String] = []
        if domainURL == nil { missing.append("yunxiaoDomain") }
        if organizationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("organizationId")
        }
        if pipelines.isEmpty { missing.append("pipelines") }
        return missing
    }
}

// MARK: - 文件名

extension BuildConfig {

    /// 被 git 忽略的本地文件名。
    static let localFileName = "buildconfig.local.json"
    /// App Support 目录下的文件名。
    static let applicationSupportFileName = "buildconfig.json"
    /// 承载它的 App Support 子目录名。
    static let applicationSupportDirectoryName = "AndroidBuildClient"
    /// 覆盖配置路径的环境变量名。
    static let pathEnvironmentKey = "ANDROID_BUILD_CLIENT_CONFIG"
    /// 从当前工作目录向上查找的层数。
    static let searchDepth = 5

    /// `~/Library/Application Support/AndroidBuildClient`。
    static var supportDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: applicationSupportDirectoryName)
    }
}

// MARK: - 查找与加载

extension BuildConfig {

    /// 候选路径，按优先级排列。已存在的文件排在前面。
    static func candidateURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> [URL] {
        var candidates: [URL] = []

        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        if let supportDirectory {
            candidates.append(supportDirectory.appending(path: applicationSupportFileName))
        }

        // 从工作目录向上找，便于在仓库根目录直接运行。
        var directory = workingDirectory
        for _ in 0...searchDepth {
            candidates.append(directory.appending(path: localFileName))
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        return candidates
    }

    /// 实际生效的配置文件路径。没有找到时抛出 `.notFound`。
    static func resolveURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> URL {
        let candidates = candidateURLs(environment: environment, workingDirectory: workingDirectory)
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw BuildConfigError.notFound(searched: candidates.map(\.path))
        }
        return url
    }

    /// 加载配置。找不到文件时抛出 `.notFound`，并带上已查找过的路径。
    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> BuildConfig {
        try load(from: resolveURL(environment: environment, workingDirectory: workingDirectory))
    }

    /// 从指定文件加载。
    static func load(from url: URL) throws -> BuildConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BuildConfigError.unreadable(path: url.path, reason: String(describing: type(of: error)))
        }

        let config: BuildConfig
        do {
            config = try JSONDecoder().decode(BuildConfig.self, from: data)
        } catch {
            throw BuildConfigError.invalid(path: url.path, reason: Self.shortReason(for: error))
        }

        let missing = config.missingFields
        guard missing.isEmpty else {
            throw BuildConfigError.missingFields(path: url.path, fields: missing)
        }
        return config
    }

    /// 把 `DecodingError` 压成一句人能读的话，不输出整个文件内容。
    private static func shortReason(for error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: type(of: error))
        }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "缺少字段 `\(key.stringValue)`"
        case .typeMismatch(_, let context):
            return "字段类型不匹配（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case .valueNotFound(_, let context):
            return "字段值为空（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case .dataCorrupted(let context):
            return "格式错误：\(context.debugDescription)"
        @unknown default:
            return "未知解析错误"
        }
    }
}

// MARK: - 错误

enum BuildConfigError: Error, Sendable, Equatable {
    /// 所有候选路径都没有配置文件。
    case notFound(searched: [String])
    /// 文件存在但读不出来。
    case unreadable(path: String, reason: String)
    /// JSON 结构不合法。
    case invalid(path: String, reason: String)
    /// JSON 合法但必填项缺失。
    case missingFields(path: String, fields: [String])
}

extension BuildConfigError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            """
            未找到本地配置文件。
            请在下列任一位置创建（内容参考仓库根目录的 buildconfig.example.json）：
            \(searched.map { "  · \($0)" }.joined(separator: "\n"))
            推荐第 2 个：它与工作目录无关，Xcode 直接 Run 也能读到。
            """
        case .unreadable(let path, let reason):
            "无法读取配置文件 \(path)：\(reason)。"
        case .invalid(let path, let reason):
            "配置文件 \(path) 格式不正确：\(reason)。"
        case .missingFields(let path, let fields):
            "配置文件 \(path) 缺少必填项：\(fields.joined(separator: "、"))。"
        }
    }
}
