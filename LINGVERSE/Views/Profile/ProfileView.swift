import SwiftUI

/// 我的 / 设置。书源管理、书架统计、关于。
struct ProfileView: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerViewModel
    @State private var isDiagnosticsPresented = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SourceListView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("书源管理")
                            Text("\(store.sources.count) 条已导入 · \(store.audioSources.count) 条可用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
            }

            Section("书架") {
                LabeledContent("已收藏", value: "\(library.books.count) 本")
                if let book = player.currentBook {
                    LabeledContent("正在播放", value: book.name)
                }
            }

            Section("设置") {
                Button {
                    isDiagnosticsPresented = true
                } label: {
                    Label("运行诊断", systemImage: "stethoscope")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("我的")
        .sheet(isPresented: $isDiagnosticsPresented) {
            NavigationStack { DiagnosticsView() }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("名称", value: "聆境 LINGVERSE")
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
            Section {
                Text("书源格式兼容 Legado。音频源（bookSourceType = 1）可直接导入使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
    }
}
