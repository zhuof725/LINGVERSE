import SwiftUI

/// 根视图：三个 Tab + 迷你播放条。
///
/// 迷你条用 `safeAreaInset` 挂在 **TabView 的每个页面里** 而不是 TabView 本身。
/// 上一版挂在 TabView 上，insets 会被 TabBar 吃掉，条子跑到 TabBar 底下。
struct RootTabView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @StateObject private var store = SourceStore.shared
    @StateObject private var library = LibraryStore.shared

    @State private var selectedTab: AppTab = .library
    @State private var isPlayerPresented = false

    enum AppTab: Hashable {
        case library, store, profile
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
            .modifier(MiniPlayerInset(isPresented: $isPlayerPresented))
            .tabItem { Label("书库", systemImage: "books.vertical") }
            .tag(AppTab.library)

            NavigationStack {
                StoreView()
            }
            .modifier(MiniPlayerInset(isPresented: $isPlayerPresented))
            .tabItem { Label("书城", systemImage: "storefront") }
            .tag(AppTab.store)

            NavigationStack {
                ProfileView()
            }
            .modifier(MiniPlayerInset(isPresented: $isPlayerPresented))
            .tabItem { Label("我的", systemImage: "person") }
            .tag(AppTab.profile)
        }
        .sheet(isPresented: $isPlayerPresented) {
            PlayerView()
        }
        .onOpenURL { url in
            // 支持从「文件」App 或分享面板把书源 JSON 交给 LINGVERSE
            handleIncoming(url)
        }
    }

    private func handleIncoming(_ url: URL) {
        guard url.isFileURL else { return }
        // 从「文件」App / 分享面板进来的文件需要安全作用域权限，否则读出来是空
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            Diagnostics.shared.add("import", "读取失败: \(url.lastPathComponent)")
            return
        }
        // 分享文本未必是 UTF-8，走和导入页一样的编码嗅探
        let text = HTTPClient.decode(data, response: nil)
        do {
            let report = try SourceStore.shared.importJSON(text)
            Diagnostics.shared.add("import", "\(url.lastPathComponent): " + report.summary)
            selectedTab = .profile
        } catch {
            Diagnostics.shared.add("import", "失败: \(error.localizedDescription)")
        }
    }
}

/// 给页面底部加迷你播放条的 inset。
private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: PlayerViewModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentBook != nil {
                MiniPlayerBar { isPresented = true }
            }
        }
    }
}
