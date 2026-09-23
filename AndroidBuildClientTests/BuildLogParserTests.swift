import Foundation
import Testing

@testable import AndroidBuildClient

/// `BuildLogParser` 的单元测试。
///
/// 解析器是整条链路里**唯一能完全离线验证**的一环，所以这里的覆盖要求最高。
/// 日志样例取自流水线真实输出（主机名与版本号替换为占位值，避免把生产域名写进源码）。
@Suite("日志解析")
struct BuildLogParserTests {

    private let parser = BuildLogParser()

    /// 一段贴近真实的日志：Gradle 输出 + 服务端裁剪提示 + 两行结果标记。
    private static let realLog = """
    [INFO] The system has omitted 6778 lines of logs. Please check the original log file for complete logs
    [11:12:29] > Task :app:assembleDebug
    [11:15:04] BUILD SUCCESSFUL in 2m 35s
    [11:15:10] 开始上传 APK
    [11:17:53] 上传完成->https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk
    [11:17:53] 二维码地址->https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png
    [11:17:54] 通知发送完成
    """

    // MARK: - 正常日志

    @Test("真实日志可以解析出 APK 与二维码地址")
    func parsesBothURLs() {
        let artifacts = parser.parse(Self.realLog)

        #expect(
            artifacts.apkURL?.absoluteString
                == "https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0.apk"
        )
        #expect(
            artifacts.qrCodeURL?.absoluteString
                == "https://apk.example.com/apk/example-app/debug/2026/0922/ExampleApp_debug_v1.0.0_qrcode.png"
        )
    }

    @Test("服务端的日志裁剪提示不影响解析")
    func ignoresTruncationNotice() {
        // 裁剪行数每次都不同，客户端不依赖它，也不去算"最后 N 行"。
        let artifacts = parser.parse(Self.realLog)

        #expect(artifacts.apkURL != nil)
        #expect(artifacts.qrCodeURL != nil)
    }

    @Test("URL 精确到第一个空白字符为止，不吞掉后续日志")
    func stopsAtWhitespace() {
        let logs = """
        上传完成->https://apk.example.com/a/x.apk BUILD SUCCESSFUL
        二维码地址->https://apk.example.com/a/x_qrcode.png
        """

        let artifacts = parser.parse(logs)

        #expect(artifacts.apkURL?.absoluteString == "https://apk.example.com/a/x.apk")
        #expect(artifacts.qrCodeURL?.absoluteString == "https://apk.example.com/a/x_qrcode.png")
    }

    @Test("同一标记出现多次时取最后一次")
    func takesLastOccurrence() {
        let logs = """
        上传完成->https://apk.example.com/first.apk
        上传完成->https://apk.example.com/last.apk
        二维码地址->https://apk.example.com/first_qrcode.png
        二维码地址->https://apk.example.com/last_qrcode.png
        """

        let artifacts = parser.parse(logs)

        #expect(artifacts.apkURL?.absoluteString == "https://apk.example.com/last.apk")
        #expect(artifacts.qrCodeURL?.absoluteString == "https://apk.example.com/last_qrcode.png")
    }

    // MARK: - 缺少结果

    @Test("没有 APK URL 时，APK 字段为 nil")
    func missingAPKURL() {
        let logs = """
        [11:15:04] BUILD SUCCESSFUL in 2m 35s
        [11:17:53] 二维码地址->https://apk.example.com/a/x_qrcode.png
        """

        let artifacts = parser.parse(logs)

        #expect(artifacts.apkURL == nil)
        #expect(artifacts.qrCodeURL?.absoluteString == "https://apk.example.com/a/x_qrcode.png")
        #expect(!artifacts.isEmpty)
    }

    @Test("没有二维码 URL 时，二维码字段为 nil，APK 仍然可用")
    func missingQRCodeURL() {
        let logs = """
        [11:15:04] BUILD SUCCESSFUL in 2m 35s
        [11:17:53] 上传完成->https://apk.example.com/a/x.apk
        """

        let artifacts = parser.parse(logs)

        #expect(artifacts.apkURL?.absoluteString == "https://apk.example.com/a/x.apk")
        #expect(artifacts.qrCodeURL == nil)
        #expect(!artifacts.isEmpty)
    }

    @Test("两个标记都没有时是空结果")
    func noMarkersAtAll() {
        let logs = """
        [11:12:29] > Task :app:assembleDebug
        [11:15:04] BUILD FAILED in 2m 35s
        """

        let artifacts = parser.parse(logs)

        #expect(artifacts.isEmpty)
        #expect(artifacts.apkURL == nil)
        #expect(artifacts.qrCodeURL == nil)
    }

    @Test("标记在但值是空的，不算解析到结果")
    func emptyValueIsNotAResult() {
        let artifacts = parser.parse("上传完成->\n二维码地址->")

        #expect(artifacts.isEmpty)
    }

    @Test("空日志不会崩溃，返回空结果")
    func emptyLogIsHandled() {
        #expect(parser.parse("").isEmpty)
    }

    // MARK: - 日志里出现多个 URL

    @Test("日志里有多个 URL 时，只取标记后面那一个")
    func picksOnlyTheMarkedURLAmongMany() {
        let logs = """
        [11:10:00] 仓库地址：https://code.example.com/example-app/app.git
        [11:12:29] 依赖下载：https://maven.example.com/android/gradle-8.5.zip
        [11:15:04] 构建缓存：https://cache.example.com/build/7788
        [11:17:53] 上传完成->https://apk.example.com/a/x.apk
        [11:17:53] 二维码地址->https://apk.example.com/a/x_qrcode.png
        [11:17:54] 文档：https://docs.example.com/example-app
        """

        let artifacts = parser.parse(logs)

        // 前面四个 URL 一个都不能被误当成结果。
        #expect(artifacts.apkURL?.absoluteString == "https://apk.example.com/a/x.apk")
        #expect(artifacts.qrCodeURL?.absoluteString == "https://apk.example.com/a/x_qrcode.png")
    }

    @Test("标记后面跟的不是 http(s) 地址时不解析")
    func rejectsNonHTTPValue() {
        let artifacts = parser.parse("上传完成->ftp://files.example.com/a/x.apk")

        #expect(artifacts.apkURL == nil)
    }

    @Test("APK 与二维码标记的顺序颠倒也能正确对应字段")
    func orderOfMarkersDoesNotMatter() {
        let logs = """
        二维码地址->https://apk.example.com/a/x_qrcode.png
        上传完成->https://apk.example.com/a/x.apk
        """

        let artifacts = parser.parse(logs)

        #expect(artifacts.apkURL?.absoluteString == "https://apk.example.com/a/x.apk")
        #expect(artifacts.qrCodeURL?.absoluteString == "https://apk.example.com/a/x_qrcode.png")
    }

    @Test("相同标记混在多行构建输出里仍取最后一次")
    func lastOccurrenceInLongLog() {
        // 模拟"重试了一次构建"的场景：第一次的产物已经被覆盖。
        var lines: [String] = []
        for index in 0..<500 {
            lines.append("[11:0\(index % 10):00] 编译中 \(index)")
        }
        lines.append("上传完成->https://apk.example.com/retry-old.apk")
        lines.append("上传完成->https://apk.example.com/retry-new.apk")

        let artifacts = parser.parse(lines.joined(separator: "\n"))

        #expect(artifacts.apkURL?.absoluteString == "https://apk.example.com/retry-new.apk")
    }
}
