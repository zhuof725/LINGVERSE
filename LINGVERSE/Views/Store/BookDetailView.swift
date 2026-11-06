import SwiftUI
import UIKit

/// 书籍详情 + 目录。
///
/// 布局参考主流有声书 App：
///   顶部大封面（模糊铺底 + 清晰主图）→ 标题/作者 → 数据行 → 标签+简介
///   → Tab 栏 → 章节列表 → 底部固定操作栏
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
    @State private var tab: DetailTab = .chapters
    @State private var isIntroExpanded = false
    @State private var isAscending = true
    @State private var query = ""
    @State private var isSearching = false
    @State private var playError: String?

    enum DetailTab: String, CaseIterable {
        case chapters = "节目列表"
        case intro = "简介"
        case source = "书源"
    }

    private var source: BookSource? {
        store.sources.first { $0.id == result.sourceId }
    }

    private var onShelf: Bool {
        library.contains(name: result.name, author: result.author)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                contentView
            }
        }
        .navigationTitle(detail?.name ?? result.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { load() }
        .alert("播放失败", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好") { playError = nil }
        } message: {
            Text(playError ?? "")
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在读取详情与目录…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试") { load() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 主内容

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader
                statsRow
                tagAndIntro
                tabBar
                tabContent
            }
        }
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - 顶部大图

    private var heroHeader: some View {
        ZStack(alignment: .bottom) {
            // 背景：同一张封面放大 + 模糊 + 压暗，铺满顶部
            AsyncImage(url: coverURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(white: 0.16)
            }
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 28)
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.25), .black.opacity(0.55), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )
            )

            HStack(alignment: .bottom, spacing: 14) {
                // 前景：清晰封面
                AsyncImage(url: coverURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.12))
                        .overlay(Image(systemName: "book.closed")
                            .foregroundStyle(.white.opacity(0.6)))
                }
                .frame(width: 104, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail?.name ?? result.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .font(.caption)
                        Text(authorText)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.8))

                    Text(source?.bookSourceName ?? result.sourceName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .frame(height: 360)
    }

    private var coverURL: URL? {
        (detail?.coverUrl ?? result.item.coverUrl).flatMap(URL.init(string:))
    }

    private var authorText: String {
        if let a = detail?.author, !a.isEmpty { return a }
        return result.author.isEmpty ? "未知作者" : result.author
    }

    // MARK: - 数据行

    /// 数据行。用数组驱动，避免「最后一格后面多一条分隔线」这类手写判断错误。
    private var statItems: [(value: String, label: String, highlight: Bool)] {
        var items: [(String, String, Bool)] = []
        if let status = statusText {
            items.append((status, "状态", true))
        }
        if let count = detail?.chapterCount, count > 0 {
            items.append((formatCount(count), "集数", false))
        }
        if let play = detail?.playCount, play > 0 {
            items.append((formatCount(play), "播放量", false))
        }
        if let words = detail?.wordCount ?? result.item.wordCount,
           let n = Int(words.filter(\.isNumber)), n > 0 {
            items.append((formatCount(n), "字数", false))
        } else if let d = detail?.duration, d > 0 {
            items.append((formatDuration(d), "总时长", false))
        }
        return items
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(statItems.enumerated()), id: \.offset) { offset, item in
                statCell(value: item.value, label: item.label, highlight: item.highlight)
                if offset < statItems.count - 1 { divider }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var statusText: String? {
        guard let f = detail?.isFinished else { return nil }
        return f ? "已完结" : "连载中"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 26)
    }

    private func statCell(value: String, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(highlight ? Color.accentColor : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 标签 + 简介

    private var tagAndIntro: some View {
        let tags = detail?.tags ?? []
        let intro = detail?.intro ?? result.item.intro ?? ""
        let hasTags = !tags.isEmpty
        let hasIntro = !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Group {
            if hasTags || hasIntro {
                VStack(alignment: .leading, spacing: 12) {
                    if hasTags {
                        // 两行流式布局：超出换行，不横向滚动（滚动容易被误当成可点）
                        FlowLayout(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if hasIntro {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(intro)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .lineLimit(isIntroExpanded ? nil : 3)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isIntroExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(isIntroExpanded ? "收起" : "更多")
                                    Image(systemName: isIntroExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9))
                                }
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    // MARK: - Tab 栏

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(DetailTab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { tab = item }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tabLabel(item))
                                .font(.subheadline.weight(tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? .primary : .secondary)
                            Rectangle()
                                .fill(tab == item ? Color.accentColor : .clear)
                                .frame(width: 22, height: 2.5)
                                .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
            Divider()
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func tabLabel(_ item: DetailTab) -> String {
        switch item {
        case .chapters: return chapters.isEmpty ? "节目列表" : "节目列表 \(chapters.count)"
        case .intro: return "简介"
        case .source: return "书源"
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .chapters: chapterSection
        case .intro: introSection
        case .source: sourceSection
        }
    }

    // MARK: - 章节列表

    /// 章节按集数倒序（新→旧）是次要需求，反转只在显示时做。
    private var visibleChapters: [SourceChapter] {
        let base = isAscending ? chapters : chapters.reversed()
        guard !query.isEmpty else { return Array(base) }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var chapterSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isAscending.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isAscending ? "arrow.up.arrow.down" : "arrow.down.arrow.up")
                            .font(.caption)
                        Text(isAscending ? "从旧到新" : "从新到旧")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if isSearching {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.caption)
                        TextField("搜章节", text: $query)
                            .font(.caption)
                            .textFieldStyle(.plain)
                            .frame(maxWidth: 140)
                        Button {
                            query = ""
                            isSearching = false
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
                } else {
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass").font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if chapters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("没有章节")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("这条书源的 ruleToc 可能依赖登录或已失效")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                let list = visibleChapters
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { offset, chapter in
                        chapterRow(chapter, displayIndex: offset + 1)
                        if offset < list.count - 1 {
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func chapterRow(_ chapter: SourceChapter, displayIndex: Int) -> some View {
        let isCurrent = player.currentBook?.bookUrl == detail?.bookUrl
            && player.currentChapter?.title == chapter.title

        return Button {
            play(chapter)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(displayIndex)")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 24, alignment: .trailing)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 5) {
                    Text(chapter.title)
                        .font(.subheadline)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        if let dur = chapterDuration(chapter) {
                            Label(dur, systemImage: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let ut = chapter.updateTime, !ut.isEmpty {
                            Text(ut)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 4)

                Group {
                    if loadingChapterIndex == chapter.index {
                        ProgressView().scaleEffect(0.7)
                    } else if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.circle")
                            .foregroundStyle(Color.accentColor)
                            .font(.subheadline)
                    } else {
                        Image(systemName: "play.circle")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                    }
                }
                .frame(width: 24)
                .padding(.top, 1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingChapterIndex != nil)
    }

    /// 章节时长。书源的 updateTime 里常带「2043 字 · ≈7:15」，直接显示原文更有信息量。
    private func chapterDuration(_ chapter: SourceChapter) -> String? {
        guard let ut = chapter.updateTime, !ut.isEmpty else { return nil }
        // 番茄源把字数+估时塞在 updateTime 里
        if ut.contains("≈") { return ut }
        return nil
    }

    // MARK: - 简介 / 书源

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(detail?.name ?? result.name)
                .font(.headline)
            Text(detail?.intro ?? result.item.intro ?? "暂无简介")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if !detailTagsOrKind.isEmpty {
                Divider()
                ForEach(detailTagsOrKind, id: \.0) { pair in
                    HStack(alignment: .top, spacing: 10) {
                        Text(pair.0)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        Text(pair.1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var detailTagsOrKind: [(String, String)] {
        var rows: [(String, String)] = []
        if let kind = detail?.kind, !kind.isEmpty { rows.append(("分类", kind)) }
        if let tags = detail?.tags, !tags.isEmpty { rows.append(("标签", tags.joined(separator: " · "))) }
        if let last = detail?.lastChapter, !last.isEmpty { rows.append(("最新章节", last)) }
        if let wc = detail?.wordCount ?? result.item.wordCount, !wc.isEmpty {
            rows.append(("字数", wc))
        }
        return rows
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoRow("书源", source?.bookSourceName ?? result.sourceName)
            Divider().padding(.leading, 18)
            infoRow("地址", detail?.bookUrl ?? result.item.bookUrl, monospaced: true)
            if let toc = detail?.tocUrl {
                Divider().padding(.leading, 18)
                infoRow("目录接口", toc, monospaced: true)
            }
            Divider().padding(.leading, 18)
            Button {
                UIPasteboard.general.string = detail?.bookUrl ?? result.item.bookUrl
            } label: {
                HStack {
                    Label("复制书籍地址", systemImage: "doc.on.doc")
                        .font(.footnote)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func infoRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 10, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                toggleShelf()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: onShelf ? "checkmark" : "plus")
                        .font(.footnote.weight(.semibold))
                    Text(onShelf ? "已在书架" : "订阅收藏")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(onShelf ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)

            Button {
                continuePlay()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.footnote)
                    Text(playButtonTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(chapters.isEmpty)
            .opacity(chapters.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var playButtonTitle: String {
        if player.currentBook?.bookUrl == detail?.bookUrl, let c = player.currentChapter {
            return player.isPlaying ? "暂停" : "续播 \(c.title)"
        }
        return chapters.isEmpty ? "暂无节目" : "从头播放"
    }

    // MARK: - 格式化

    private func formatCount(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分钟"
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
                    let info = try SourcePipeline.shared.bookInfo(
                        result.item.bookUrl, source: source, hint: result.item)
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
                    playError = "这一章没解析出音频地址。可在「书源 → 运行诊断」查看规则输出。"
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
                playError = error.localizedDescription
            }
        }
    }

    /// 底部主按钮：正在播这本书就切播放/暂停，否则从头播。
    private func continuePlay() {
        if player.currentBook?.bookUrl == detail?.bookUrl {
            player.togglePlay()
            return
        }
        guard let first = chapters.first else { return }
        play(first)
    }

    private func toggleShelf() {
        if onShelf {
            library.remove(name: result.name, author: result.author)
        } else if let detail, let source {
            library.add(LBook(detail: detail, sourceId: source.id, sourceName: source.bookSourceName))
        }
    }
}

// MARK: - 流式布局

/// 标签用的简易流式布局。
/// iOS 16+ 的 Layout 协议实现：按可用宽度自动换行，行内间距一致。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
