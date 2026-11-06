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
        var wordCount: String?
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
        if items.isEmpty {
            // 空列表是「搜不到」的唯一征兆，但没有异常。把原始响应长度和
            // 前 200 字符记下来，才能判断是响应本身不对，还是规则没解析出来。
            Diagnostics.shared.add("search", "响应 \(body.count) 字符，前 200：\(body.prefix(200))")
            if let jsErr = JSRunner.shared.lastError {
                Diagnostics.shared.add("search", "js 错误：\(jsErr)")
            }
        }

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
                lastChapter: RuleEngine.eval(rule.lastChapter, itemCtx, json: item).string.nilIfEmpty,
                wordCount: RuleEngine.eval(rule.wordCount, itemCtx, json: item).string.nilIfEmpty
            )
        }
    }

    // MARK: - 详情

    /// 抓详情页，拿到书名/作者/封面/简介，以及目录地址（tocUrl）。
    func bookInfo(_ bookURL: String, source: BookSource, hint: SearchResult? = nil) throws -> BookDetail {
        let rule = source.ruleBookInfo
        Diagnostics.shared.add("bookInfo", "bookUrl=\(bookURL.prefix(90))")
        guard !bookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.badURL("bookUrl 为空（搜索结果的 bookUrl 规则没产出地址）")
        }
        var ctx = RuleContext(baseURL: bookURL)
        ctx.book = ["name": hint?.name ?? "", "bookUrl": bookURL, "author": hint?.author ?? ""]
        ctx.jsLib = source.jsLib ?? ""
        ctx.vars["__sourceUrl"] = source.bookSourceUrl
        ctx.vars["__sourceName"] = source.bookSourceName
        ctx.vars["__sourceKey"] = source.bookSourceUrl

        // init 规则：有些源靠它抓真实详情接口（常带签名头），返回值就是详情内容
        var detailURL = bookURL
        var detailSpec: RequestSpec?

        // init 规则：它自己抓详情接口，返回的是**详情内容本身**（通常是一段 JSON），
        // 后续 name/author 等规则都在这个返回值上求值 —— 不是「返回一个 URL」。
        // 之前把它当成「置换 detailURL」用，于是 name/author 拿到的是空，
        // 详情页只剩下标题，表现为「加载失败」。
        var initBody: String?
        if let initRule = rule?.`init`, !initRule.isEmpty {
            let seed = HTTPClient.shared.get(bookURL) ?? ""
            var initCtx = ctx
            initCtx.body = seed
            let produced = RuleEngine.eval(initRule, initCtx, json: RuleEngine.parseJSON(seed)).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !produced.isEmpty, produced != "{}" {
                initBody = produced
            }
            Diagnostics.shared.add("bookInfo", "init 产出 \(produced.count) 字符")
            if produced == "{}" || produced.count <= 2 {
                // 书源自己的 try/catch 会吞掉所有异常，这里必须把线索留下来
                Diagnostics.shared.add("bookInfo", "init 失败 · seed \(seed.count) 字符 · js错误 \(JSRunner.shared.lastError ?? "无")")
            }
        }

        let body: String
        if let initBody {
            body = initBody
        } else if let spec = detailSpec {
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
            intro: field(rule?.intro).plainTextFromMarkup ?? hint?.intro,
            kind: field(rule?.kind).nilIfEmpty ?? hint?.kind,
            coverUrl: absolute(field(rule?.coverUrl), base: detailURL),
            lastChapter: field(rule?.lastChapter).nilIfEmpty ?? hint?.lastChapter,
            wordCount: field(rule?.wordCount).nilIfEmpty
        )
        ctx.book = ["name": detail.name, "author": detail.author, "bookUrl": detail.bookUrl]

        // 详情页要展示的统计信息。各书源字段名不同，按常见候选依次找。
        // 取不到就留空，界面上那一格自动省略 —— 不要显示 0，那是在撒谎。
        if let obj = json as? [String: Any] {
            detail.chapterCount = Self.intValue(obj, keys: ["serial_count", "chapter_number",
                                                            "chapter_count", "totalChapter"])
            detail.playCount = Self.intValue(obj, keys: ["listen_count", "play_count",
                                                          "read_count_all", "listen_dcnt"])
            if let d = Self.doubleValue(obj, keys: ["duration", "total_duration"]) {
                detail.duration = d > 0 ? d : nil
            }
            if let tags = obj["tags"] as? String {
                let parts: [String] = tags
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "|" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                detail.tags = Array(parts.prefix(6))
            }
            // 番茄：update_status 0 = 完结。别的源可能用 is_finished。
            if let s = obj["update_status"] as? NSNumber {
                detail.isFinished = s.intValue == 0
            } else if let f = obj["is_finished"] as? Bool {
                detail.isFinished = f
            }
        }

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
        ctx.book = ["name": detail.name, "author": detail.author, "bookUrl": detail.bookUrl]
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
            let updateTime = RuleEngine.eval(rule.updateTime, itemCtx, json: item).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(SourceChapter(
                index: index,
                title: title.isEmpty ? "第 \(index + 1) 章" : title,
                url: url,
                isVip: RuleEngine.eval(rule.isVip, itemCtx, json: item).string.contains("true"),
                updateTime: updateTime.isEmpty ? nil : updateTime
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
        // 规则里会读 book.bookUrl 来提取 book_id，只给 name 不够
        ctx.book = ["name": detail.name, "author": detail.author, "bookUrl": detail.bookUrl]
        ctx.chapter = ["title": chapter.title, "index": String(chapter.index), "url": chapterURL]
        ctx.jsLib = source.jsLib ?? ""
        ctx.vars["__sourceUrl"] = source.bookSourceUrl
        ctx.vars["__sourceName"] = source.bookSourceName
        ctx.vars["__sourceKey"] = source.bookSourceUrl

        // 章节地址可能只是「参数载体」（番茄的 mcs.zijieapi.com/list?item_id=... 根本
        // 不是给人看的页面），也可能本身就是音频直链。
        // 所以：能抓就抓，抓不到也继续跑规则 —— 规则自己会发请求。
        var body = ""
        if AudioURL.isDirect(chapterURL) {
            return [chapterURL]
        }
        if let spec = try? RequestSpec.parse(chapterURL, base: chapterURL),
           let fetched = HTTPClient.shared.request(spec.url, method: spec.method, body: spec.body,
                                                   headers: spec.headers, timeout: 20) {
            body = fetched
        }
        ctx.body = body

        let raw = RuleEngine.eval(contentRule, ctx, json: RuleEngine.parseJSON(body)).string
        let found = AudioURL.parse(raw, base: chapterURL)
        if !found.isEmpty { return found }
        return AudioURL.isDirect(chapterURL) ? [chapterURL] : []
    }

    // MARK: - 辅助

    /// 从 JSON 里按候选字段名取整数。字符串形式的数字也接受。
    private static func intValue(_ obj: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let n = obj[key] as? NSNumber { return n.intValue }
            if let s = obj[key] as? String, let v = Int(s) { return v }
        }
        return nil
    }

    private static func doubleValue(_ obj: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let n = obj[key] as? NSNumber { return n.doubleValue }
            if let s = obj[key] as? String, let v = Double(s) { return v }
        }
        return nil
    }

    private func baseURL(of source: BookSource) -> String {
        // bookSourceUrl 可能带 `##` 注释后缀，取前半
        let raw = source.bookSourceUrl
        let base = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把列表项塞进上下文。
    ///
    /// 注意：**不把条目的字段注入成全局变量**。之前那样做踩过坑 ——
    /// 书源字段名（`anchor`、`name`、`top`…）会和 JS 宿主对象重名
    /// （`anchor` 是 window.anchor），结果 `String(result.anchor)` 拿到的是
    /// `function anchor() { [native code] }`。
    /// 正确语义是让脚本从 `result` 里取当前条目，这里只做上下文继承。
    private func ctxWithItem(_ item: [String: Any], base: RuleContext) -> RuleContext {
        var ctx = base
        // 只透传少数几个确定安全的标量，供模板 `{{字段}}` 使用
        for key in ["book_id", "bookId", "id"] {
            if let v = item[key] { ctx.vars[key] = "\(v)" }
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

    // MARK: 详情页展示用（来自各书源的扩展字段，没有就省略）
    /// 章节总数（番茄的 serial_count / chapter_number）
    var chapterCount: Int?
    /// 全书时长（秒）
    var duration: TimeInterval?
    /// 播放量
    var playCount: Int?
    /// 标签，逗号分隔
    var tags: [String] = []
    /// 连载状态：true = 已完结
    var isFinished: Bool = false
}

struct SourceChapter: Identifiable, Hashable {
    var id: String { "\(index)#\(url)" }
    var index: Int
    var title: String
    var url: String
    var isVip: Bool = false
    /// 书源 ruleToc.updateTime 的原文。番茄源在这里塞了「2043 字 · ≈7:15」，
    /// 直接展示比解析成时间更有用。
    var updateTime: String?
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

    /// 书源的简介字段经常是 HTML / `<useweb>` 富文本面板（给阅读界面渲染用的）。
    /// 原生列表直接显示会看到一堆标签，这里剥成纯文本。
    var plainTextFromMarkup: String? {
        var t = self
        if t.contains("<") {
            // 去掉 script/style 段
            t = t.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>",
                                       with: "", options: [.regularExpression, .caseInsensitive])
            t = t.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>",
                                       with: "", options: [.regularExpression, .caseInsensitive])
            // 块级标签转换行
            t = t.replacingOccurrences(of: "<(br|/p|/div|/li)[^>]*>",
                                       with: "\n", options: [.regularExpression, .caseInsensitive])
            // 其余标签全去掉
            t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            // 实体
            let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                            "&quot;": "\"", "&#39;": "'", "&hellip;": "…", "&mdash;": "—"]
            for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        }
        // 压缩空白
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
