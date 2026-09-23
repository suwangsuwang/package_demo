import SwiftUI

@main
struct AndroidBuildClientApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        Window("AndroidBuildClient", id: "main") {
            RootView()
                .environment(appModel)
                .frame(minWidth: 460, minHeight: 540)
                .task {
                    // 启动流程：读 Keychain → 有 Token 就验证 → 决定页面。
                    // Token 的读取只发生在 TokenStore / APIClient 内部，不经过界面。
                    await appModel.bootstrapToken()
                }
        }
        .defaultSize(width: 560, height: 660)
        .windowResizability(.contentMinSize)
    }
}
