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
    @State private var isPlayerPresented = false
    /// 下拉回弹时多拉出来的距离，用来把封面同步拉长
    @State private var pullOffset: CGFloat = 0

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
        // 顶部是整幅封面，导航栏不能占位：改成透明背景 + 只留返回箭头。
        // 书名已经压在图上，标题栏再显示一遍就是重复信息，而且会盖住图。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { load() }
        .sheet(isPresented: $isPlayerPresented) {
            PlayerView()
        }
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

    /// 上半部分（图片 + 数据行 + 标签 + 简介）整体压在深色底上，
    /// 和目标图一致：从封面往下颜色连续，到 Tab 栏才切成浅色。
    private static let heroBackground = Color(red: 0.11, green: 0.10, blue: 0.10)
    private static let heroDivider = Color.white.opacity(0.14)

    private var contentView: some View {
        // 安全区顶高度在 GeometryReader 里可能因为 ignoresSafeArea 变成 0，
        // 所以从窗口读一次固定值。
        let topInset = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 0
        return ScrollView {
            VStack(spacing: 0) {
                heroHeader(pull: pullOffset)
                    .background(
                        ScrollOffsetReader { offset in
                            let pull = max(-offset, 0)
                            if abs(pull - pullOffset) > 0.5 {
                                pullOffset = pull
                            }
                        }
                        .frame(height: 0)
                    )

                statsRow
                tagAndIntro
                tabBar
                tabContent
            }
            // 负 padding 把内容顶到屏幕物理顶端。
            // ScrollView 默认从安全区下方开始排内容，
            // 只加 ignoresSafeArea 影响的是背景而不是内容位置 ——
            // 用户截图里顶部那一大块白就是这么来的。
            .padding(.top, -topInset)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .scrollDismissesKeyboard(.immediately)
        .ignoresSafeArea(edges: [.top, .horizontal])
    }

    // MARK: - 顶部大图

    /// 顶部大图区。
    ///
    /// 参考布局：一张封面**整幅**铺满（不模糊、不裁成小方块），
    /// 底部压一层深色渐变，标题/作者/书源直接叠在图上。
    ///
    /// `pull` 是下拉回弹的距离（ScrollView 内容顶部超出屏幕的高度）。
    /// 大于 0 时把图片高度加上这段，图片就跟着手指一起拉长，不会露出背景。
    private func heroHeader(pull: CGFloat) -> some View {
        let extra = max(pull, 0)
        return GeometryReader { geo in
            let h = geo.size.height
            // 注意结构：图片放在 background 里，不参与 ZStack 的尺寸计算。
            // 如果图片直接放进 ZStack，它 h+extra 的高度会把 ZStack 撑大，
            // 标题就被推到可见区之外 —— 用户截图里标题消失就是这个原因。
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.55), location: 0.0),
                        .init(color: .black.opacity(0.05), location: 0.28),
                        .init(color: .black.opacity(0.55), location: 0.62),
                        .init(color: .black.opacity(0.95), location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 8) {
                    Text(detail?.name ?? result.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)

                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 15))
                        Text(authorText)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.88))

                    HStack(spacing: 5) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                        Text(source?.bookSourceName ?? result.sourceName)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
            .frame(width: geo.size.width, height: h, alignment: .bottomLeading)
            // 图片作为背景层：高度 h + 下拉距离，底部对齐，
            // 多出来的部分向上溢出（不会撑大 ZStack，标题位置不受影响）。
            .background(alignment: .bottom) {
                coverImage
                    .frame(width: geo.size.width, height: h + extra)
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    /// 封面图。用 scaledToFill 保持比例裁切，
    /// 不能用 .aspectRatio(contentMode: .fill) —— 外面套固定宽高 frame 时它会失效，
    /// 图片被直接拉伸变形。
    @ViewBuilder
    private func coverImage() -> some View {
        AsyncImage(url: coverURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable()
                    .scaledToFill()
                    .clipped()
            case .failure:
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.25))
                }
            default:
                Rectangle()
                    .fill(Color(white: 0.14))
                    .overlay(ProgressView().tint(.white.opacity(0.6)))
            }
        }
    }

    /// 顶部高度。用屏高的 52% 而不是固定值：
    /// 小屏（SE）和大屏（Pro Max）都能压住版面，不会出现「图很矮、下面一堆空白」。
    /// UIScreen.main 在 iOS 17 已 deprecated，但在 iOS 17 上仍然可用且无警告等级问题。
    private var heroHeight: CGFloat {
        let screen = UIScreen.main.bounds.height
        return min(max(screen * 0.52, 340), 470)
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
        // 字数优先。总时长（「221小时0分」）太长，四格会被挤变形，
        // 而且字数更有信息量 —— 有字数就不显示时长。
        if let words = detail?.wordCount ?? result.item.wordCount,
           let n = Int(words.filter(\.isNumber)), n > 0 {
            items.append((formatCount(n), "字数", false))
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
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(Self.heroBackground)
    }

    private var statusText: String? {
        guard let f = detail?.isFinished else { return nil }
        return f ? "已完结" : "连载中"
    }

    private var divider: some View {
        Rectangle()
            .fill(Self.heroDivider)
            .frame(width: 0.5, height: 30)
    }

    private func statCell(value: String, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(highlight ? Color(red: 0.35, green: 0.62, blue: 1.0) : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    // MARK: - 标签 + 简介

    private var tagAndIntro: some View {
        let tags = detail?.tags ?? []
        let intro = detail?.intro ?? result.item.intro ?? ""
        let hasTags = !tags.isEmpty
        let hasIntro = !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Group {
            if hasTags || hasIntro {
                VStack(alignment: .leading, spacing: 14) {
                    if hasTags {
                        // 流式换行。第一个标签高亮（书源常把最重要的分类放首位）
                        FlowLayout(spacing: 8) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                                Text(tag)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(
                                        index == 0
                                        ? Color(red: 0.24, green: 0.42, blue: 0.78).opacity(0.55)
                                        : Color.white.opacity(0.10),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(index == 0 ? .white : .white.opacity(0.72))
                            }
                        }
                    }

                    if hasIntro {
                        // 简介整块放进深色圆角卡片，「简介：」作为内联前缀
                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                Text("简介：").fontWeight(.medium)
                                    .foregroundStyle(.white.opacity(0.9))
                                + Text(intro)
                                    .foregroundStyle(.white.opacity(0.62))
                            }
                            .font(.system(size: 13.5))
                            .lineSpacing(4)
                            .lineLimit(isIntroExpanded ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isIntroExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(isIntroExpanded ? "收起" : "更多")
                                    Image(systemName: isIntroExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 18)
                .background(Self.heroBackground)
            } else {
                // 没有标签也没有简介时，仍要有一段深色收尾，避免图片直接贴到白底
                Self.heroBackground.frame(height: 18)
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
                        VStack(spacing: 7) {
                            Text(tabLabel(item))
                                .font(.system(size: 16, weight: tab == item ? .bold : .regular))
                                .foregroundStyle(tab == item ? .primary : .secondary)
                            // 选中项下面一小段横线，未选中留空占位，避免切换时行高跳动
                            Capsule()
                                .fill(tab == item ? Color.primary : Color.clear)
                                .frame(width: 26, height: 3)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 10)
            Divider()
        }
        .background(Color(.systemBackground))
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
            HStack(alignment: .top, spacing: 10) {
                // 序号单独一列，字号略大，和标题有明显层级差
                Text("\(displayIndex)")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary.opacity(0.55))
                    .frame(width: 26, alignment: .trailing)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(chapter.title)
                        .font(.system(size: 15))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // 第二行：时长 + 日期 + 播放量。书源能给什么就显示什么
                    HStack(spacing: 8) {
                        if let ut = chapter.updateTime, !ut.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                Text(ut)
                            }
                        }
                        if let date = chapter.publishDate, !date.isEmpty {
                            Text(date)
                        }
                        if isCurrent {
                            HStack(spacing: 3) {
                                Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                    .font(.system(size: 8))
                                Text(player.isPlaying ? "播放中" : "已暂停")
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Group {
                    if loadingChapterIndex == chapter.index {
                        ProgressView().scaleEffect(0.65)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(90))
                    }
                }
                .frame(width: 22)
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
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
        VStack(spacing: 0) {
            // 正在播别的书时，底部栏上方浮一条迷你播放条（和目标图一致）
            if player.currentBook?.bookUrl != detail?.bookUrl, player.currentBook != nil {
                MiniPlayerBar { isPlayerPresented = true }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            HStack(spacing: 12) {
                Button {
                    toggleShelf()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: onShelf ? "checkmark" : "heart")
                            .font(.system(size: 15, weight: .medium))
                        Text(onShelf ? "已在书架" : "订阅收藏")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(onShelf ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)

                Button {
                    continuePlay()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                        Text(playButtonTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(red: 0.90, green: 0.24, blue: 0.24),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(chapters.isEmpty)
                .opacity(chapters.isEmpty ? 0.45 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
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
