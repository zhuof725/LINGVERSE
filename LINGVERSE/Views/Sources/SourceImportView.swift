import SwiftUI
import UniformTypeIdentifiers

/// 导入书源。三条路：
/// 1. 文件——从「文件」App 选 .json / .txt（很多书源分享就是 txt）
/// 2. 剪贴板——复制了分享文本直接粘
/// 3. 链接——raw.githubusercontent / gist / 网盘直链
///
/// 三条路最后都汇到 `SourceStore.importJSON`，保证行为一致。
struct SourceImportView: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var urlText = ""
    @State private var isDownloading = false
    @State private var isPickingFile = false
    @State private var alert: AlertItem?
    @State private var importedCount: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                    Button {
                        importFromClipboard()
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                } footer: {
                    Text("书源分享常见两种形态：JSON 文件，或一段 Base64 / 明文分享文本。剪贴板里有什么就直接读什么。")
                }

                Section("从链接导入") {
                    HStack {
                        TextField("https://…/sources.json", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            importFromURL()
                        } label: {
                            if isDownloading {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Text("获取")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isDownloading || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("直接粘贴书源 JSON…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    HStack {
                        Text("粘贴")
                        Spacer()
                        Button("清空") { text = "" }
                            .font(.caption)
                            .disabled(text.isEmpty)
                    }
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { performImport(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [.json, .plainText, .text, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileResult(result)
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
            }
        }
    }

    // MARK: - 文件

    private func handleFileResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alert = AlertItem(title: "选择文件失败", message: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            // 沙箱外的文件必须先申请安全作用域访问权限，否则读出来是空的
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                alert = AlertItem(title: "读取失败", message: "无法读取 \(url.lastPathComponent)")
                return
            }
            // 书源文件编码不一定是 UTF-8（老分享文本常是 GBK）
            let content = HTTPClient.decode(data, response: nil)
            performImport(content, from: url.lastPathComponent)
        }
    }

    // MARK: - 剪贴板

    private func importFromClipboard() {
        guard let raw = UIPasteboard.general.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alert = AlertItem(title: "剪贴板是空的", message: "先复制书源 JSON 或分享文本。")
            return
        }
        performImport(raw, from: "剪贴板")
    }

    // MARK: - 链接

    private func importFromURL() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: raw) != nil else {
            alert = AlertItem(title: "地址无效", message: raw)
            return
        }
        isDownloading = true
        Task {
            defer { isDownloading = false }
            guard let body = HTTPClient.shared.get(raw, timeout: 30) else {
                alert = AlertItem(title: "下载失败", message: "确认这个链接能在浏览器里直接打开并返回 JSON。")
                return
            }
            performImport(body, from: "链接")
        }
    }

    // MARK: - 统一入口

    private func performImport(_ raw: String, from origin: String? = nil) {
        do {
            let report = try store.importJSON(raw)
            importedCount = report.added + report.updated
            let prefix = origin.map { "来源：\($0)\n" } ?? ""
            alert = AlertItem(title: "导入完成", message: prefix + report.summary)
            text = ""
            urlText = ""
        } catch {
            // 导入失败时把内容留在输入框里，方便用户改，不要清空
            text = raw
            alert = AlertItem(
                title: "导入失败",
                message: "\(error.localizedDescription)\n\n内容开头：\n\(raw.prefix(160))"
            )
        }
    }
}
