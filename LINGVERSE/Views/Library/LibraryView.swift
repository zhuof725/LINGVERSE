import SwiftUI

/// 书库 = 书架。展示已收藏的书，点击继续播放。
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerViewModel

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    ContentUnavailableView {
                        Label("书架是空的", systemImage: "books.vertical")
                    } description: {
                        Text("去「书城」搜索有声书，点右上角 ⊕ 加入书架。")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(library.books) { book in
                                BookCardView(book: book, isPlaying: player.currentBook?.bookUrl == book.bookUrl) {
                                    resume(book)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("书库")
            .toolbar {
                if !library.books.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
        }
    }

    private func resume(_ book: LBook) {
        // 已经切到别的书：让用户去详情页选章节，比这里猜一章更符合预期
        if player.currentBook?.bookUrl == book.bookUrl {
            player.togglePlay()
            return
        }
        // 同书不同章不重复加载
        Task {
            guard let source = SourceStore.shared.sources.first(where: { $0.id == book.sourceId }) else {
                Diagnostics.shared.add("library", "书源不存在: \(book.sourceName)")
                return
            }
            do {
                let detail = BookDetail(
                    bookUrl: book.bookUrl, name: book.name, author: book.author,
                    intro: book.intro, kind: book.kind, coverUrl: book.coverUrl,
                    lastChapter: book.lastChapter, wordCount: nil, tocUrl: nil)
                let chapters = try await Task.detached(priority: .userInitiated) {
                    try SourcePipeline.shared.toc(detail, source: source)
                }.value
                guard let first = chapters.first else { return }
                let urls = try await Task.detached(priority: .userInitiated) {
                    try SourcePipeline.shared.playURLs(chapter: first, detail: detail, source: source)
                }.value
                guard let url = urls.first.flatMap(URL.init(string:)) else { return }
                player.load(
                    book: book,
                    chapter: LChapter(index: first.index, title: first.title, url: first.url),
                    audioURL: url,
                    allChapters: chapters.map { LChapter(index: $0.index, title: $0.title, url: $0.url) }
                )
            } catch {
                Diagnostics.shared.add("library", "打开失败: \(error.localizedDescription)")
            }
        }
    }
}
