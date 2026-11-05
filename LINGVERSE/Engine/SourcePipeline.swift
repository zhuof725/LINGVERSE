import Foundation

/// 书源流水线：搜索 → 详情 → 目录 → 章节播放地址。
///
/// 每一步都独立可测（`SourcePipeline` 不持有 UI 状态），
/// 失败原因写进 `Diagnostics` 并向上抛，调用方决定要不要提示用户。
final class SourcePipeline {
    static let shared = SourcePipeline()

    private init() {}

    // MARK: - URL 构造

    /// 展开 searchUrl / tocUrl 这类「URL 规则」，返回可执行的请求。
    ///
    /// 返回值可能是 `url, {"method":"POST","headers":{...}}` ——
    /// API 型书源（番茄等）几乎全靠这个约定把签名头带进去。
    func expandRequest(_ rule: String, ctx: RuleContext, json: Any? = nil) throws -> RequestSpec {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SourceError.missingRule("URL 规则") }

        let expanded: String
        if let script = RuleScanner.scriptBody(text) {
            expanded = JSRunner.shared.run(script, ctx: ctx, json: json)
            // JS 抛异常时返回空串。这里必须区分「脚本失败」和「脚本返回了空」，
            // 否则用户看到的是「生成了非法地址」，完全无法定位。
            if expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let reason = JSRunner.shared.lastError ?? "脚本返回空"
                throw SourceError.scriptFailed(reason)
            }
        } else {
            expanded = RuleEngine.expandTemplate(text, ctx: ctx, json: json)
        }

        guard let spec = RequestSpec.parse(expanded, base: ctx.baseURL) else {
            throw SourceError.badURL(expanded)
        }
        return spec
    }

    /// 兼容旧调用：只要 URL。
    func expandURL(_ rule: String, ctx: RuleContext, json: Any? = nil) -> String? {
        try? expandRequest(rule, ctx: ctx, json: json).url
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
        // jsLib 里是签名函数和常量，规则脚本直接调用它
        ctx.jsLib = source.jsLib ?? ""
        ctx.vars["__sourceUrl"] = source.bookSourceUrl
        ctx.vars["__sourceName"] = source.bookSourceName
        ctx.vars["__sourceKey"] = source.bookSourceUrl

        let spec = try expandRequest(searchRuleText, ctx: ctx)
        Diagnostics.shared.add("search", "\(source.bookSourceName) → \(spec.method) \(spec.url)")
        if !spec.headers.isEmpty {
            Diagnostics.shared.add("search", "headers: \(spec.headers.keys.sorted().joined(separator: ", "))")
        }

        guard let body = HTTPClient.shared.request(
            spec.url, method: spec.method, body: spec.body, headers: spec.headers, timeout: 25
        ) else {
            throw SourceError.requestFailed(spec.url)
        }
        ctx.body = body
        ctx.baseURL = spec.url
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
            let bookURL = absolute(rawURL, base: spec.url) ?? rawURL
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
        ctx.jsLib = source.jsLib ?? ""
        ctx.vars["__sourceUrl"] = source.bookSourceUrl
        ctx.vars["__sourceName"] = source.bookSourceName
        ctx.vars["__sourceKey"] = source.bookSourceUrl

        // init 规则：有些源靠它把 bookUrl 换成真实详情接口（常带签名头）
        var detailURL = bookURL
        var detailSpec: RequestSpec?
        if let initRule = rule?.`init`, !initRule.isEmpty {
            ctx.body = HTTPClient.shared.get(bookURL) ?? ""
            detailSpec = try? expandRequest(initRule, ctx: ctx, json: RuleEngine.parseJSON(ctx.body))
            if let spec = detailSpec { detailURL = spec.url }
        }

        let body: String
        if let spec = detailSpec {
            body = HTTPClient.shared.request(spec.url, method: spec.method, body: spec.body,
                                             headers: spec.headers, timeout: 25) ?? ""
        } else {
            body = HTTPClient.shared.get(detailURL) ?? ""
        }
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

        // 目录地址：优先 tocUrl 规则，否则就当 bookUrl 本身是目录页。
        // tocUrl 规则往往产出「URL + 签名头」的 POST 请求，光存 URL 会丢掉 headers，
        // 所以返回的 detail 里把整个 spec 带上，toc() 直接用。
        if let tocRule = rule?.tocUrl, !tocRule.isEmpty {
            if let spec = try? expandRequest(tocRule, ctx: ctx, json: json) {
                detail.tocRequest = spec
                detail.tocUrl = spec.url
            } else {
                detail.tocUrl = detailURL
            }
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
        ctx.jsLib = source.jsLib ?? ""
        ctx.vars["__sourceUrl"] = source.bookSourceUrl
        ctx.vars["__sourceName"] = source.bookSourceName
        ctx.vars["__sourceKey"] = source.bookSourceUrl

        let body: String?
        if let spec = detail.tocRequest {
            Diagnostics.shared.add("toc", "\(spec.method) \(spec.url.prefix(100))")
            body = HTTPClient.shared.request(spec.url, method: spec.method, body: spec.body,
                                             headers: spec.headers, timeout: 25)
        } else {
            body = HTTPClient.shared.get(tocURL)
        }
        guard let body else {
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
        ctx.jsLib = source.jsLib ?? ""
        ctx.vars["__sourceUrl"] = source.bookSourceUrl
        ctx.vars["__sourceName"] = source.bookSourceName
        ctx.vars["__sourceKey"] = source.bookSourceUrl

        // 章节地址可能是「URL + 签名头」，也可能是普通的页面 URL。
        // 先用章节地址抓一次，拿不到再退回纯 GET。
        var body: String?
        if let spec = try? RequestSpec.parse(chapterURL, base: chapterURL) {
            body = HTTPClient.shared.request(spec.url, method: spec.method, body: spec.body,
                                             headers: spec.headers, timeout: 25)
        }
        if body == nil { body = HTTPClient.shared.get(chapterURL) }
        guard let body else {
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
    /// 目录请求的完整参数。tocUrl 规则常产出带签名头的 POST，
    /// 只存 URL 会让 toc() 重新发明一次请求，签名就失效了。
    var tocRequest: RequestSpec?
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
    /// 规则脚本抛异常。必须和 badURL 分开：
    /// 真实原因通常是 jsLib 缺失、宿主 API 没实现、或签名算法报错，
    /// 混成「非法地址」会把最有价值的信息丢掉。
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRule(let name): return "书源缺少 \(name) 规则"
        case .badURL(let raw): return "规则没有产出合法地址：\(raw.prefix(120))"
        case .requestFailed(let url): return "请求失败：\(url.prefix(120))"
        case .scriptFailed(let reason): return "规则脚本执行失败：\(reason.prefix(200))"
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
