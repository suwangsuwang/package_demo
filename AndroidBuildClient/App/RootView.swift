import SwiftUI

/// 顶层页面容器。
struct RootView: View {

    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.route {
            case .tokenSetup:
                TokenSetupView()
            case .build:
                BuildView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: appModel.route)
    }
}
