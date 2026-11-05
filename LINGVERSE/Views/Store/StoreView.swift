import SwiftUI

/// 书城 = 搜索入口。选中音频源后按关键字搜索，结果可直接加入书架。
struct StoreView: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var library: LibraryStore

    @State private var keyword = ""
    @State private var isSearching = false
    @State private var results: [SourceSearchResult] = []
    @State private var errorMessage: String?
    @State private var searchedWith = 0

    var body: some View {
        NavigationStack {
            Group {
                if store.audioSources.isEmpty {
                    ContentUnavailableView {
                        Label("没有可用的音频源", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text("先去「我的 → 书源管理」导入至少一条 bookSourceType 为 1 的书源。")
                    }
                } else if isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在搜索 \(store.audioSources.count) 条书源…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView {
                        Label("搜索有声书", systemImage: "magnifyingglass")
                    } description: {
                        Text(errorMessage ?? "输入书名或作者，会在所有启用的音频源里查找。")
                    }
                } else {
                    resultList
                }
            }
            .navigationTitle("书城")
            .searchable(text: $keyword, prompt: "书名 / 作者")
            .onSubmit(of: .search) { search() }
        }
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(results) { result in
                    NavigationLink {
                        BookDetailView(result: result)
                    } label: {
                        resultRow(result)
                    }
                }
            } header: {
                Text("找到 \(results.count) 本 · 来自 \(searchedWith) 条源")
            }
        }
        .refreshable { search() }
    }

    private func resultRow(_ result: SourceSearchResult) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.coverURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            .frame(width: 48, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(result.author.isEmpty ? "未知作者" : result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = result.lastChapter, !last.isEmpty {
                    Text("更新至 \(last)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if library.contains(name: result.name, author: result.author) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let sources = store.audioSources
        guard !sources.isEmpty else { return }

        isSearching = true
        results = []
        errorMessage = nil
        searchedWith = sources.count

        Task {
            var collected: [SourceSearchResult] = []
            var failures: [String] = []

            await withTaskGroup(of: (BookSource, Result<[SourcePipeline.SearchResult], Error>).self) { group in
                for source in sources {
                    group.addTask {
                        let result = await Task.detached(priority: .userInitiated) {
                            Result { try SourcePipeline.shared.search(q, source: source) }
                        }.value
                        return (source, result)
                    }
                }
                for await (source, result) in group {
                    switch result {
                    case .success(let list):
                        collected.append(contentsOf: list.map {
                            SourceSearchResult(sourceId: source.id, sourceName: source.bookSourceName, item: $0)
                        })
                    case .failure(let error):
                        failures.append("\(source.bookSourceName): \(error.localizedDescription)")
                    }
                }
            }

            await MainActor.run {
                results = collected
                isSearching = false
                if collected.isEmpty {
                    errorMessage = failures.isEmpty
                        ? "没有找到结果。"
                        : "全部 \(searchedWith) 条源都失败了：\n" + failures.prefix(3).joined(separator: "\n")
                }
            }
        }
    }
}

/// 搜索结果带上来源信息，后续详情/目录都要用它找到对应书源。
struct SourceSearchResult: Identifiable {
    let id = UUID()
    let sourceId: String
    let sourceName: String
    let item: SourcePipeline.SearchResult

    var name: String { item.name }
    var author: String { item.author }
    var coverURL: URL? { item.coverUrl.flatMap(URL.init(string:)) }
    var lastChapter: String? { item.lastChapter }
}
