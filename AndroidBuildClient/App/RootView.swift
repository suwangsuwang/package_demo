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
                // ⚠️ NavigationStack 只包住 `.build` 分支，**不包住 switch**。
                //
                // 它属于「Build 工作区内部的导航」这一层，与 `appModel.route`
                // 表达的「当前是哪个顶层工作区」是两件事，两者刻意不合并：
                // - `route` 由 Token 校验/保存的结果驱动，那件事与导航栈无关；
                // - 导航路径只被 Build 子树读读写写，让 Token 页面也参与进来
                //   只会把「切到配置页」和「从历史详情返回」缠成一套状态。
                //
                // 放在分支内部还有个副作用正是我们要的：`switch` 的两个 case
                // 视图类型不同、身份天然不同，所以切到配置页再切回来时
                // `NavigationStack` 会整棵重建 —— 将来历史详情被 push 进栈后，
                // 去配置页转一圈回来会自然回到 Build 根页，不需要额外清理代码。
                //
                // ⚠️ 本阶段用无参构造：还没有任何页面可以 push。
                // 不建 `path` —— 没有消费者的状态只会多出一份生命周期要验证。
                NavigationStack {
                    BuildView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: appModel.route)
    }
}
