import SwiftUI

/// 书籍详情 + 目录。抓详情、列章节、点章节开始播放。
struct BookDetailView: View {
    let result: SourceSearchResult

    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var detail: BookDetail?
    @State private var chapters: [SourceChapter] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadingChapterIndex: Int?

    private var source: BookSource? {
        store.sources.first { $0.id == result.sourceId }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("读取目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { load() }
                }
            } else {
                content
            }
        }
        .navigationTitle(detail?.name ?? result.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleShelf()
                } label: {
                    Image(systemName: onShelf ? "checkmark.circle.fill" : "plus.circle")
                }
            }
        }
        .task { load() }
    }

    private var onShelf: Bool {
        library.contains(name: result.name, author: result.author)
    }

    private var content: some View {
        List {
            Section {
                header
            }

            Section {
                ForEach(chapters) { chapter in
                    Button {
                        play(chapter)
                    } label: {
                        HStack(spacing: 8) {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer()
                            if loadingChapterIndex == chapter.index {
                                ProgressView()
                            } else if isCurrent(chapter) {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .disabled(loadingChapterIndex != nil)
                }
            } header: {
                Text("目录 · \(chapters.count) 章")
            }
        }
        .listStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: detail?.coverUrl.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            .frame(width: 80, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(detail?.author.isEmpty == false ? detail!.author : result.author)
                    .font(.subheadline)
                Text("来源：\(result.sourceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let kind = detail?.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                if let last = detail?.lastChapter, !last.isEmpty {
                    Text("最新：\(last)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func isCurrent(_ chapter: SourceChapter) -> Bool {
        player.currentBook?.bookUrl == detail?.bookUrl && player.currentChapter?.title == chapter.title
    }

    // MARK: - 数据

    private func load() {
        guard let source else {
            errorMessage = "书源已被删除"
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let info = try SourcePipeline.shared.bookInfo(result.item.bookUrl, source: source, hint: result.item)
                    let list = try SourcePipeline.shared.toc(info, source: source)
                    return (info, list)
                }.value
                detail = loaded.0
                chapters = loaded.1
                if chapters.isEmpty {
                    errorMessage = "目录为空。这条书源的 ruleToc 可能依赖登录或已失效，可在「书源 → 运行诊断」里看日志。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func play(_ chapter: SourceChapter) {
        guard let source, let detail else { return }
        loadingChapterIndex = chapter.index

        Task {
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try SourcePipeline.shared.playURLs(chapter: chapter, detail: detail, source: source)
                }.value
                loadingChapterIndex = nil
                guard let first = urls.first.flatMap(URL.init(string:)) else {
                    errorMessage = "这一章没解析出音频地址。可在「书源 → 运行诊断」查看规则输出。"
                    return
                }
                let book = LBook(detail: detail, sourceId: source.id, sourceName: source.bookSourceName)
                let lchapter = LChapter(index: chapter.index, title: chapter.title, url: chapter.url)
                player.load(book: book, chapter: lchapter, audioURL: first,
                            allChapters: chapters.map {
                                LChapter(index: $0.index, title: $0.title, url: $0.url)
                            })
            } catch {
                loadingChapterIndex = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func toggleShelf() {
        if onShelf {
            library.remove(name: result.name, author: result.author)
        } else if let detail, let source {
            library.add(LBook(detail: detail, sourceId: source.id, sourceName: source.bookSourceName))
        }
    }
}
