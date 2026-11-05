import Foundation

/// 书源流水线：搜索 → 详情 → 目录 → 章节播放地址。
///
/// 每一步都独立可测（`SourcePipeline` 不持有 UI 状态），
/// 失败原因写进 `Diagnostics` 并向上抛，调用方决定要不要提示用户。
final class SourcePipeline {
    static let shared = SourcePipeline()

    private init() {}

    // MARK: - URL 构造

    /// 展开 searchUrl / tocUrl 这类「URL 规则」，返回补全后的绝对地址。
    /// 支持 `@js:` 脚本、`{{key}}` `{{page}}` 模板、`{{$.field}}` JSON 引用。
    func expandURL(_ rule: String, ctx: RuleContext, json: Any? = nil) -> String? {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let expanded: String
        if let script = RuleScanner.scriptBody(text) {
            expanded = JSRunner.shared.run(script, ctx: ctx, json: json)
        } else {
            expanded = RuleEngine.expandTemplate(text, ctx: ctx, json: json)
        }
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 脚本可能返回带换行的多行文本，取第一行像 URL 的
        for line in trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let candidate = String(line).trimmingCharacters(in: .whitespaces)
            if candidate.lowercased().hasPrefix("http") { return candidate }
        }
        if trimmed.lowercased().hasPrefix("http") { return trimmed }
        return absolute(trimmed, base: ctx.baseURL)
    }

    /// 相对地址补全。`//cdn.x/a` 补成 https。
    func absolute(_ raw: String, base: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
        if t.hasPrefix("//") { return "https:" + t }
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: t, relativeTo: baseURL)?.absoluteString
    }

    // MARK: - 搜索

    struct SearchResult {
        var name: String
        var author: String
        var bookUrl: String
        var coverUrl: String?
        var intro: String?
        var kind: String?
        var lastChapter: String?
    }

    /// 用一条书源搜索关键字。`page` 从 1 开始。
    func search(_ keyword: String, source: BookSource, page: Int = 1) throws -> [SearchResult] {
        guard let rule = source.ruleSearch else {
            throw SourceError.missingRule("ruleSearch")
        }
        guard let searchRuleText = source.searchUrl, !searchRuleText.isEmpty else {
            throw SourceError.missingRule("searchUrl")
        }

        var ctx = RuleContext(baseURL: baseURL(of: source), key: keyword, page: page)
        ctx.vars["key"] = keyword
        ctx.vars["page"] = String(page)

        guard let url = expandURL(searchRuleText, ctx: ctx) else {
            throw SourceError.badURL(searchRuleText)
        }
        Diagnostics.shared.add("search", "\(source.bookSourceName) → \(url)")

        guard let body = HTTPClient.shared.get(url, timeout: 20) else {
            throw SourceError.requestFailed(url)
        }
        ctx.body = body
        ctx.baseURL = url
        let json = RuleEngine.parseJSON(body)

        let items = RuleEngine.evalList(rule.bookList, ctx, json: json)
        Diagnostics.shared.add("search", "bookList \(items.count) 条")

        return items.compactMap { item in
            let itemCtx = ctxWithItem(item, base: ctx)
            let name = RuleEngine.eval(rule.name, itemCtx, json: item).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            // bookUrl 常写成 `{{$.url}}` 需要原始 item 当 JSON 源
            var urlCtx = itemCtx
            urlCtx.body = body
            let rawURL = RuleEngine.eval(rule.bookUrl, urlCtx, json: item).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bookURL = absolute(rawURL, base: url) ?? rawURL
            return SearchResult(
                name: name,
                author: RuleEngine.eval(rule.author, itemCtx, json: item).string,
                bookUrl: bookURL,
                coverUrl: RuleEngine.eval(rule.coverUrl, itemCtx, json: item).string.nilIfEmpty,
                intro: RuleEngine.eval(rule.intro, itemCtx, json: item).string.nilIfEmpty,
                kind: RuleEngine.eval(rule.kind, itemCtx, json: item).string.nilIfEmpty,
                lastChapter: RuleEngine.eval(rule.lastChapter, itemCtx, json: item).string.nilIfEmpty
            )
        }
    }

    // MARK: - 详情

    /// 抓详情页，拿到书名/作者/封面/简介，以及目录地址（tocUrl）。
    func bookInfo(_ bookURL: String, source: BookSource, hint: SearchResult? = nil) throws -> BookDetail {
        let rule = source.ruleBookInfo
        var ctx = RuleContext(baseURL: bookURL)
        ctx.book = ["name": hint?.name ?? ""]

        // init 规则：有些源靠它把 bookUrl 换成真实详情接口
        var detailURL = bookURL
        if let initRule = rule?.`init`, !initRule.isEmpty {
            ctx.body = HTTPClient.shared.get(bookURL) ?? ""
            if let resolved = expandURL(initRule, ctx: ctx, json: RuleEngine.parseJSON(ctx.body)) {
                detailURL = resolved
            }
        }

        let body = HTTPClient.shared.get(detailURL) ?? ""
        ctx.body = body
        ctx.baseURL = detailURL
        let json = RuleEngine.parseJSON(body)

        func field(_ ruleText: String?) -> String {
            RuleEngine.eval(ruleText, ctx, json: json).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let name = field(rule?.name).nilIfEmpty ?? hint?.name ?? ""
        var detail = BookDetail(
            bookUrl: bookURL,
            name: name,
            author: field(rule?.author).nilIfEmpty ?? hint?.author ?? "",
            intro: field(rule?.intro).nilIfEmpty ?? hint?.intro,
            kind: field(rule?.kind).nilIfEmpty ?? hint?.kind,
            coverUrl: absolute(field(rule?.coverUrl), base: detailURL),
            lastChapter: field(rule?.lastChapter).nilIfEmpty ?? hint?.lastChapter,
            wordCount: field(rule?.wordCount).nilIfEmpty
        )
        ctx.book = ["name": detail.name, "author": detail.author]

        // 目录地址：优先 tocUrl 规则，否则就当 bookUrl 本身是目录页
        if let tocRule = rule?.tocUrl, !tocRule.isEmpty {
            detail.tocUrl = expandURL(tocRule, ctx: ctx, json: json) ?? detailURL
        } else {
            detail.tocUrl = detailURL
        }
        return detail
    }

    // MARK: - 目录

    func toc(_ detail: BookDetail, source: BookSource) throws -> [SourceChapter] {
        guard let rule = source.ruleToc else { throw SourceError.missingRule("ruleToc") }
        let tocURL = detail.tocUrl ?? detail.bookUrl
        var ctx = RuleContext(baseURL: tocURL)
        ctx.book = ["name": detail.name, "author": detail.author]

        guard let body = HTTPClient.shared.get(tocURL) else {
            throw SourceError.requestFailed(tocURL)
        }
        ctx.body = body
        let json = RuleEngine.parseJSON(body)

        if let pre = rule.preUpdateJs, !pre.isEmpty {
            _ = JSRunner.shared.run(pre, ctx: ctx, json: json)
        }

        let items = RuleEngine.evalList(rule.chapterList, ctx, json: json)
        Diagnostics.shared.add("toc", "\(detail.name) \(items.count) 章")

        var chapters: [SourceChapter] = []
        for (index, item) in items.enumerated() {
            let itemCtx = ctxWithItem(item, base: ctx)
            var urlCtx = itemCtx
            urlCtx.body = body
            let title = RuleEngine.eval(rule.chapterName, itemCtx, json: item).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawURL = RuleEngine.eval(rule.chapterUrl, urlCtx, json: item).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = absolute(rawURL, base: tocURL) else { continue }
            chapters.append(SourceChapter(
                index: index,
                title: title.isEmpty ? "第 \(index + 1) 章" : title,
                url: url,
                isVip: RuleEngine.eval(rule.isVip, itemCtx, json: item).string.contains("true")
            ))
        }
        return chapters
    }

    // MARK: - 播放地址

    /// 取章节的音频地址。
    ///
    /// 三种情况（照 bookon 的 AudioChapter 语义）：
    /// 1. 章节地址本身就是音频直链 → 直接用，不发请求；
    /// 2. 书源配了 ruleContent.content → 抓章节页跑规则，从结果里解析地址；
    /// 3. 规则跑不出来但章节地址像音频 → 兜底用章节地址。
    func playURLs(chapter: SourceChapter, detail: BookDetail, source: BookSource) throws -> [String] {
        let chapterURL = chapter.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chapterURL.isEmpty else { return [] }

        let contentRule = source.ruleContent?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if contentRule.isEmpty {
            return AudioURL.isDirect(chapterURL) ? [chapterURL] : []
        }

        var ctx = RuleContext(baseURL: chapterURL)
        ctx.book = ["name": detail.name, "author": detail.author]
        ctx.chapter = ["title": chapter.title, "index": String(chapter.index), "url": chapterURL]

        guard let body = HTTPClient.shared.get(chapterURL) else {
            if AudioURL.isDirect(chapterURL) { return [chapterURL] }
            throw SourceError.requestFailed(chapterURL)
        }
        ctx.body = body

        let raw = RuleEngine.eval(contentRule, ctx, json: RuleEngine.parseJSON(body)).string
        let found = AudioURL.parse(raw, base: chapterURL)
        if !found.isEmpty { return found }
        return AudioURL.isDirect(chapterURL) ? [chapterURL] : []
    }

    // MARK: - 辅助

    private func baseURL(of source: BookSource) -> String {
        // bookSourceUrl 可能带 `##` 注释后缀，取前半
        let raw = source.bookSourceUrl
        let base = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把列表项塞进上下文，让 `{{$.name}}` 这类模板能取到当前项。
    private func ctxWithItem(_ item: [String: Any], base: RuleContext) -> RuleContext {
        var ctx = base
        for (k, v) in item {
            if let s = v as? String { ctx.vars[k] = s }
        }
        return ctx
    }
}

// MARK: - 数据模型

struct BookDetail {
    var bookUrl: String
    var name: String
    var author: String
    var intro: String?
    var kind: String?
    var coverUrl: String?
    var lastChapter: String?
    var wordCount: String?
    var tocUrl: String?
}

struct SourceChapter: Identifiable, Hashable {
    var id: String { "\(index)#\(url)" }
    var index: Int
    var title: String
    var url: String
    var isVip: Bool = false
}

// MARK: - 错误

enum SourceError: LocalizedError {
    case missingRule(String)
    case badURL(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRule(let name): return "书源缺少 \(name) 规则"
        case .badURL(let raw): return "规则生成了非法地址：\(raw.prefix(80))"
        case .requestFailed(let url): return "请求失败：\(url.prefix(80))"
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
