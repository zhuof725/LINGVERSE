import SwiftUI

/// 应用入口。
@main
struct LINGVERSEApp: App {
    @StateObject private var player = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(player)
        }
    }
}
