import AppKit
import Foundation

/// 调用系统默认浏览器打开 URL。
///
/// AppKit 的使用被限制在这一个文件里，其余代码不依赖 AppKit ——
/// 这样将来若要换平台或改行为，只需替换这一处。
enum URLLauncher {

    /// 在默认浏览器中打开。返回是否成功。
    @discardableResult
    @MainActor
    static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// 复制文本到剪贴板。
    @MainActor
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
