import SwiftUI

/// 应用入口
/// 空壳阶段：仅注入全局播放状态，不做真实初始化。
@main
struct LINGVERSEApp: App {
    // 全局播放状态（环境注入，供各页面共享）
    @StateObject private var player = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(player)
        }
    }
}
