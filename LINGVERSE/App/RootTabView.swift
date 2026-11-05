import SwiftUI

/// 根视图：底部 Tab 导航 + 悬浮迷你播放条
/// 空壳阶段：导航骨架真实，页面内容均为占位。
struct RootTabView: View {
    @EnvironmentObject private var player: PlayerViewModel

    @State private var selectedTab: AppTab = .library
    @State private var isPlayerPresented = false

    enum AppTab: Hashable {
        case library
        case store
        case profile
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem { Label("书库", systemImage: "books.vertical") }
                .tag(AppTab.library)

            StoreView()
                .tabItem { Label("书城", systemImage: "storefront") }
                .tag(AppTab.store)

            ProfileView()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(AppTab.profile)
        }
        // 有播放内容时，在 Tab 栏上方悬浮迷你播放条
        .safeAreaInset(edge: .bottom) {
            if player.currentBook != nil {
                MiniPlayerBar {
                    isPlayerPresented = true
                }
            }
        }
        .sheet(isPresented: $isPlayerPresented) {
            PlayerView()
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(PlayerViewModel())
}
