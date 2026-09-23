import Foundation

/// 日志解析抽象。
///
/// 刻意做成独立的小类型，而不是塞进 `BuildViewModel`：
/// 它是整条链路里**唯一可以完全离线验证**的一环（见 `BuildLogParserTests`）。
protocol BuildLogParsing: Sendable {
    func parse(_ logs: String) -> BuildArtifacts
}

/// 从流水线日志里解析打包产物地址。
///
/// 打包脚本稳定输出两行：
/// ```
/// [11:17:53] 上传完成->https://…/AioMp_debug_v3.6.1.apk
/// [11:17:53] 二维码地址->https://…/AioMp_debug_v3.6.1_qrcode.png
/// ```
///
/// 规则：
/// - 按标记取**最后一次**出现 —— 一次构建里可能重试并输出多次，最后一次才是最终产物。
/// - 标记后紧跟 URL，读到空白字符为止。
/// - 不猜文件名、不拼 URL、不访问 OSS。只认流水线自己打印的地址。
struct BuildLogParser: BuildLogParsing {

    /// 源码里的标记只此一处，其余地方引用 `AppConfiguration.LogMarker`。
    private static let patterns: [Pattern] = [
        Pattern(marker: AppConfiguration.LogMarker.uploadCompleted, isAPK: true),
        Pattern(marker: AppConfiguration.LogMarker.qrCodeAddress, isAPK: false),
    ]

    func parse(_ logs: String) -> BuildArtifacts {
        var apkURL: URL?
        var qrCodeURL: URL?

        for pattern in Self.patterns {
            guard let url = Self.url(in: logs, after: pattern.marker) else { continue }
            if pattern.isAPK {
                apkURL = url
            } else {
                qrCodeURL = url
            }
        }

        return BuildArtifacts(apkURL: apkURL, qrCodeURL: qrCodeURL)
    }

    // MARK: - 内部

    private struct Pattern {
        let marker: String
        /// APK 是核心结果，二维码是辅助结果，分别落到 `BuildArtifacts` 的对应字段。
        let isAPK: Bool
    }

    /// 取标记之后紧跟的 URL。标记出现多次时取最后一次。
    ///
    /// 用 `NSRegularExpression` 而不是字符串切割：日志里同一个标记可能出现多行，
    /// 且 URL 之后可能紧跟其它字符，正则能一次性表达"标记 + 非空白序列"。
    private static func url(in logs: String, after marker: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: marker) + "(https?://\\S+)"
        ) else {
            return nil
        }

        let range = NSRange(logs.startIndex..<logs.endIndex, in: logs)
        let matches = regex.matches(in: logs, range: range)
        guard let match = matches.last, match.numberOfRanges > 1 else { return nil }
        guard let captured = Range(match.range(at: 1), in: logs) else { return nil }

        return URL(string: String(logs[captured]))
    }
}
