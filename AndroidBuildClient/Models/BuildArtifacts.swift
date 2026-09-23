import Foundation

/// 构建产物地址。
///
/// 客户端的最终产出就是这个类型 —— 不管底层走了几个接口、日志有多长，
/// UI 只关心这两个地址。
struct BuildArtifacts: Sendable, Equatable {
    /// APK 下载地址，来自日志标记 `上传完成->`。**这是核心结果。**
    let apkURL: URL?
    /// 二维码图片地址，来自日志标记 `二维码地址->`。这是辅助结果。
    let qrCodeURL: URL?

    init(apkURL: URL? = nil, qrCodeURL: URL? = nil) {
        self.apkURL = apkURL
        self.qrCodeURL = qrCodeURL
    }

    /// 两个地址都没解析出来时视为空结果。
    var isEmpty: Bool { apkURL == nil && qrCodeURL == nil }
}
