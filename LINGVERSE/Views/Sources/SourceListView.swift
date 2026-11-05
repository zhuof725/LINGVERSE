import SwiftUI

/// 书源管理：列表 / 启用开关 / 导入 / 导出 / 删除 / 诊断。
struct SourceListView: View {
    @EnvironmentObject private var store: SourceStore
    @State private var isImporterPresented = false
    @State private var isDiagnosticsPresented = false
    @State private var alert: AlertItem?
    @State private var exportDocument: TextDocument?

    var body: some View {
        List {
            if store.sources.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有书源", systemImage: "square.and.arrow.down")
                    } description: {
                        Text("导入 Legado 格式的书源 JSON，才能搜索和播放有声书。")
                    } actions: {
                        Button("导入书源") { isImporterPresented = true }
                    }
                }
            } else {
                Section {
                    ForEach(store.sources) { source in
                        row(for: source)
                    }
                    .onDelete { store.remove(at: $0) }
                } header: {
                    Text("已导入 \(store.sources.count) 条 · 可用 \(store.audioSources.count) 条音频源")
                } footer: {
                    if store.audioSources.isEmpty && !store.sources.isEmpty {
                        Text("导入的源都不是音频源（bookSourceType 不为 1）。LINGVERSE 只播放有声书，文本源不会出现在搜索里。")
                    }
                }
            }
        }
        .navigationTitle("书源")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportCurrent()
                    } label: {
                        Label("导出全部", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.sources.isEmpty)
                    Divider()
                    Button {
                        isDiagnosticsPresented = true
                    } label: {
                        Label("运行诊断", systemImage: "stethoscope")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isImporterPresented) {
            SourceImportView()
        }
        .sheet(isPresented: $isDiagnosticsPresented) {
            NavigationStack { DiagnosticsView() }
        }
        .sheet(item: $exportDocument) { doc in
            ShareSheet(items: [doc.text])
        }
        .alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    private func row(for source: BookSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(source.bookSourceName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if source.isAudio {
                    Text("音频")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("文本")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            if let host = URL(string: source.bookSourceUrl.split(separator: "#").first.map(String.init) ?? "")?.host {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.remove(source)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.setEnabled(!source.isEnabled, for: source)
            } label: {
                Label(source.isEnabled ? "禁用" : "启用",
                      systemImage: source.isEnabled ? "pause.circle" : "play.circle")
            }
            .tint(source.isEnabled ? .orange : .green)
        }
        .opacity(source.isEnabled ? 1 : 0.5)
    }

    private func exportCurrent() {
        do {
            let json = try store.exportJSON()
            exportDocument = TextDocument(text: json, filename: "lingverse-sources.json")
        } catch {
            alert = AlertItem(title: "导出失败", message: error.localizedDescription)
        }
    }
}

// MARK: - 导入

struct SourceImportView: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var alert: AlertItem?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("粘贴 Legado 书源 JSON")
                    .font(.headline)
                Text("支持数组或单个对象，可直接粘贴书源分享文本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 240)

                Text("也可以从文件导入：用「文件」App 里的 .json 分享到 LINGVERSE。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { performImport() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
            }
        }
    }

    private func performImport() {
        do {
            let report = try store.importJSON(text)
            alert = AlertItem(title: "导入完成", message: report.summary)
            text = ""
        } catch {
            alert = AlertItem(title: "导入失败", message: error.localizedDescription)
        }
    }
}

// MARK: - 诊断

struct DiagnosticsView: View {
    @ObservedObject private var log = Diagnostics.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("暂无日志。搜索或播放后这里会出现每一步的执行记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.entries.reversed()) { entry in
                    Text(entry.line)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("运行诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") { log.clear() }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

// MARK: - 通用小件

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct TextDocument: Identifiable {
    let id = UUID()
    let text: String
    let filename: String
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
