import Foundation

/// 规则求值上下文。对应 Legado 的 AnalyzeUrl / RuleData 执行环境。
struct RuleContext {
    /// 当前请求/响应地址，相对链接按它补全。
    var baseURL: String = ""
    /// 当前响应全文（HTML 或 JSON 文本）。
    var body: String = ""
    /// 搜索关键字。
    var key: String = ""
    /// 翻页页码。
    var page: Int = 1
    /// `{{book.name}}` 这类书信息模板。
    var book: [String: String] = [:]
    /// `{{chapter.title}}`。
    var chapter: [String: String] = [:]
    /// jsLib 与源内变量（`source.getVariable()` 等）。
    var vars: [String: String] = [:]
    /// 书源自带的 jsLib 脚本。每次求值前注入，规则里才能调 `fanqieSignHeaders` 这类函数。
    var jsLib: String = ""
}

/// 规则执行结果。
enum RuleValue {
    case text(String)
    case list([[String: Any]])

    var string: String {
        switch self {
        case .text(let s): return s
        case .list(let items): return items.map { RuleValue.text(in: $0).string }.joined(separator: "\n")
        }
    }

    /// 从字典取第一个可渲染的文本值（优先常见字段名，否则取第一个字符串值）。
    static func text(in item: [String: Any]) -> RuleValue {
        for key in ["text", "value", "name", "title", "content"] {
            if let s = item[key] as? String { return .text(s) }
        }
        for (_, value) in item.sorted(by: { $0.key < $1.key }) {
            if let s = value as? String { return .text(s) }
        }
        return .text("")
    }
}

/// Legado 规则求值器。
///
/// 只实现 LINGVERSE 需要的一条链路：搜索 / 详情 / 目录 / 章节地址。
/// 刻意不做：@css 完整 XPath、段评、登录 UI、explore 富文本布局。
/// 遇到不支持的规则形态一律返回空串并记一条诊断，绝不把"求值失败"当成"字段为空"吞掉。
enum RuleEngine {

    // MARK: - 入口

    /// 解析单条规则。`ctx.body` 为当前响应，`json` 传 nil 时按需把 body 解析成 JSON 对象。
    ///
    /// `result` 的语义照 Legado：脚本里能直接用的「当前值」。
    /// 逐条解析（bookList 之后取 name/author）时它是当前条目的 JSON，
    /// 否则是整段响应正文。
    static func eval(_ rule: String?, _ ctx: RuleContext, json: Any? = nil) -> RuleValue {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .text("")
        }

        // 当前值：有 json（说明在处理列表里的某一项）就序列化它，否则给响应正文
        let currentResult: String
        if let json, !(json is String) {
            currentResult = serializeJSON(json)
        } else if let json = json as? String {
            currentResult = json
        } else {
            currentResult = ctx.body
        }

        // 0) 两段式：`<js>...</js>$[*]` 或 `@js:...</js>$[*]`
        //    JS 先产出一段 JSON，再按后面的 JSONPath 取值。
        //    真实书源（番茄畅听）的 bookList / chapterList 全是这个形态，
        //    只认前缀会把 `$[*]` 当成脚本的一部分，直接语法报错。
        if let twoPhase = splitScriptAndPath(raw) {
            let ctxJSON = json ?? parseJSON(ctx.body)
            let produced = JSRunner.shared.run(twoPhase.script, ctx: ctx, json: ctxJSON,
                                               result: ctx.body)
            if twoPhase.path.isEmpty { return .text(produced) }
            let parsed = parseJSON(produced) ?? produced
            let nodes = jsonPathNodes(twoPhase.path, parsed)
            if nodes.isEmpty { return .text("") }
            if nodes.count == 1, let s = nodes[0] as? String { return .text(s) }
            return .text(nodes.map { scalarString($0) }.joined(separator: "\n"))
        }

        // 1) 纯脚本规则（@js: / <js>）——整条规则交给 JS 引擎
        if let script = RuleScanner.scriptBody(raw) {
            let ctxJSON = json ?? RuleEngine.parseJSON(ctx.body)
            let out = JSRunner.shared.run(script, ctx: ctx, json: ctxJSON, result: currentResult)
            return .text(out)
        }

        var text = raw

        // 2) `selector@js:...` —— 先求选择器，再把结果作为 result 交给脚本
        if let range = valueScriptSplit(text) {
            let selector = String(text[..<range.lowerBound])
            let script = String(text[range.upperBound...])
            let prev = eval(selector, ctx, json: json)
            let ctxJSON = json ?? RuleEngine.parseJSON(ctx.body)
            let out = JSRunner.shared.run(script, ctx: ctx, json: ctxJSON, result: prev.string)
            return .text(out)
        }

        // 3) 模板展开：把 {{expr}} 换成求值结果
        text = expandTemplate(text, ctx: ctx, json: json)

        // 4) 字面量地址：展开后是完整 URL，直接返回。
        //    真实书源的 bookUrl 大量写成 `https://x/robots.txt?bookId={{$.book_id}}`，
        //    如果继续走 evalSelector 会被当 JSONPath，解析失败返回空串 ——
        //    表现就是「bookUrl 为空（搜索结果的 bookUrl 规则没产出地址）」。
        //    注意必须放在 expandTemplate 之后：否则含 {{}} 的 URL 会原样返回。
        if isLiteralURL(text) { return .text(text) }

        // 5) 管道：`##` 正则替换 / `&&` 交集
        return evalPipeline(text, ctx: ctx, json: json)
    }

    /// 规则展开后是不是一段字面地址 / 纯文本，而不是选择器表达式。
    static func isLiteralURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        // 含 URL 特征字符，且不像 JSONPath（没有 $. 开头）
        if !t.hasPrefix("$"), !t.hasPrefix("@"), !t.hasPrefix("<"),
           t.contains("://") || (t.contains("?") && t.contains("=")) {
            return true
        }
        return false
    }

    /// 拆出 `<js>脚本</js>` 后面跟的 JSONPath。
    /// 返回 nil 表示不是这种两段式规则。
    static func splitScriptAndPath(_ rule: String) -> (script: String, path: String)? {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)

        // 形式一：<js> ... </js> <path>
        if text.hasPrefix("<js>"), let end = text.range(of: "</js>", options: .backwards) {
            let script = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            let path = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (script, path)
        }

        // 形式二：@js: ... </js> <path>
        if text.hasPrefix("@js:"), let end = text.range(of: "</js>", options: .backwards) {
            let script = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            let path = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (script, path)
        }

        // 形式三：@js: ... 后面跟一行以 $ 开头的路径（没有 </js> 闭合）
        if text.hasPrefix("@js:") {
            let body = String(text.dropFirst(4))
            let lines = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
            if let last = lines.last {
                let tail = String(last).trimmingCharacters(in: .whitespaces)
                if tail.hasPrefix("$") && tail.count < 40 && !tail.contains(" "),
                   lines.count > 1 {
                    let script = lines.dropLast().joined(separator: "\n")
                    return (script, tail)
                }
            }
        }
        return nil
    }

    /// 求一个列表规则（bookList / chapterList），返回字典数组。
    /// 结果里每个元素都会带上 `__text` 与 `__html` 便于下游按需取值。
    static func evalList(_ rule: String?, _ ctx: RuleContext, json: Any? = nil) -> [[String: Any]] {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ctxJSON = json ?? parseJSON(ctx.body)
        // 列表脚本里的 `result` 指的是「本轮响应正文」。
        // 真实书源第一行就是 `JSON.parse(result)`，不传的话它 catch 成 {} 返回空数组，
        // 于是一条都不报错却一条都搜不到 —— 这个坑很难从界面上看出来。
        let response = ctx.body

        // 两段式 `<js>...</js>$[*]`：脚本产出 JSON，路径取数组
        if let twoPhase = splitScriptAndPath(rule) {
            let produced = JSRunner.shared.run(twoPhase.script, ctx: ctx, json: ctxJSON, result: response)
            let parsed = parseJSON(produced)
            if let path = twoPhase.path.isEmpty ? nil : twoPhase.path, let parsed {
                let nodes = jsonPathNodes(path, parsed)
                let dicts = nodes.compactMap { $0 as? [String: Any] }
                if !dicts.isEmpty { return dicts }
            }
            // 路径解析不出来时退回按 JSON 数组解析
            return JSRunner.parseList(produced)
        }

        // 纯 JS 规则可能直接返回数组
        if RuleScanner.scriptBody(rule) != nil {
            let out = JSRunner.shared.run(rule, ctx: ctx, json: ctxJSON, result: response)
            return JSRunner.parseList(out)
        }
        // JSON 数组路径
        if let obj = ctxJSON {
            let nodes = jsonPathNodes(rule, obj)
            if !nodes.isEmpty {
                return nodes.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    // MARK: - JSONPath

    /// 把规则里的 `$.` 前缀去掉后走 JsonPath。`body.data[*].books` 这种不带 `$` 的写法也接受。
    static func jsonPathNodes(_ path: String, _ root: Any) -> [Any] {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return [] }
        // 已经是完整表达式（$.x / $..x / $[0]）就原样用。
        // 之前这里对 "$.book_id" 做了 dropFirst() 再拼 "$."，变成 "$..book_id" ——
        // 递归下降，语义完全变了：会扫全树，且返回数组而非单值。
        if !p.hasPrefix("$") {
            if p.hasPrefix(".") { p = "$" + p } else { p = "$." + p }
        }
        return JsonPath.query(root, p)
    }

    static func parseJSON(_ text: String) -> Any? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first == "{" || first == "[" else { return nil }
        guard let data = t.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 把任意 JSON 对象序列化回字符串，给脚本当 `result` 用。
    static func serializeJSON(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return scalarString(n) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: - 模板

    /// 展开 `{{expression}}`。表达式支持：
    /// - `$.field.path`（相对当前 JSON）
    /// - `key` / `page` / `book.name` / `chapter.url`
    /// - `baseUrl` / `host` 等源变量
    static func expandTemplate(_ text: String, ctx: RuleContext, json: Any? = nil) -> String {
        guard text.contains("{{") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            guard let open = text[i...].range(of: "{{") else {
                out += String(text[i...])
                break
            }
            out += String(text[i..<open.lowerBound])
            guard let close = text[open.upperBound...].range(of: "}}") else {
                out += String(text[open.lowerBound...])
                break
            }
            let expr = String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += resolveTemplate(expr, ctx: ctx, json: json)
            i = close.upperBound
        }
        return out
    }

    private static func resolveTemplate(_ expr: String, ctx: RuleContext, json: Any?) -> String {
        // `$...` 或 `$.` → JSONPath
        if expr.hasPrefix("$") {
            guard let obj = json ?? parseJSON(ctx.body) else { return "" }
            let nodes = jsonPathNodes(expr, obj)
            if nodes.count == 1, let s = nodes[0] as? String { return s }
            return nodes.map { scalarString($0) }.joined(separator: ",")
        }
        // `@get:{key}` 读变量
        if expr.hasPrefix("@get:") {
            let key = String(expr.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            return ctx.vars[key] ?? ""
        }
        if expr == "key" { return ctx.key }
        if expr == "page" { return String(ctx.page) }
        if expr == "baseUrl" { return ctx.baseURL }
        if expr.hasPrefix("book.") {
            return ctx.book[String(expr.dropFirst(5))] ?? ""
        }
        if expr.hasPrefix("chapter.") {
            return ctx.chapter[String(expr.dropFirst(8))] ?? ""
        }
        if let v = ctx.vars[expr] { return v }
        // 未知表达式原样保留，方便在诊断面板里看见是哪条模板没被支持
        return "{{\(expr)}}"
    }

    private static func scalarString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if value is NSNull { return "" }
        if let n = value as? NSNumber {
            // 19 位数字（番茄的 book_id）超出 Double 的精确整数范围（2^53），
            // NSNumber.stringValue 会输出 7.233717404444921e+18 这种科学计数法，
            // 拼进 URL 就成了坏地址。这里按"是不是整数"分别处理。
            let type = String(cString: n.objCType)
            let isBool = type == "c" || type == "B"
            if isBool { return n.boolValue ? "true" : "false" }
            if type == "q" || type == "l" || type == "i" || type == "s" {
                return String(n.int64Value)   // 从 JSON 整数解析来的，精度完好
            }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e18 {
                // 能精确表示的整数：不要走 %f，避免 .0 尾巴
                return String(format: "%.0f", d)
            }
            if d == d.rounded() {
                // 大整数但已经是 double：只能尽力还原，至少不用科学计数法
                return String(format: "%.0f", d)
            }
            return n.stringValue
        }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }

    // MARK: - 管道

    /// `@js:` / `@js` 作为“值脚本”出现的位置：`selector@js:script`。
    private static func valueScriptSplit(_ text: String) -> Range<String.Index>? {
        guard let r = text.range(of: "@js:") else { return nil }
        // 只有前面确实有选择器时才算值脚本；`@js:` 在开头的情况由 scriptBody 处理
        guard r.lowerBound > text.startIndex else { return nil }
        return r
    }

    /// 依次执行 `&&`（交集/兜底）与 `##`（正则替换）。顺序按 Legado：先切 `&&`，再切 `##`。
    static func evalPipeline(_ rule: String, ctx: RuleContext, json: Any? = nil) -> RuleValue {
        let andSplit = RuleScanner.split(rule, by: ["&&"])
        if andSplit.valid && andSplit.parts.count > 1 {
            // 交集：取第一个非空结果；全空则返回空
            var last = ""
            for part in andSplit.parts {
                let v = evalPipeline(part, ctx: ctx, json: json)
                let s = v.string
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
                last = s
            }
            return .text(last)
        }

        // `##regex##replacement` 两段式 + `##regex` 单段式
        let hashSplit = RuleScanner.split(rule, by: ["##"])
        if hashSplit.valid && hashSplit.parts.count > 1 {
            let selector = hashSplit.parts[0]
            let base = evalSelector(selector, ctx: ctx, json: json).string
            var value = base
            var k = 1
            while k < hashSplit.parts.count {
                let pattern = hashSplit.parts[k]
                let replacement = (k + 1 < hashSplit.parts.count) ? hashSplit.parts[k + 1] : ""
                if pattern.isEmpty {
                    k += 2
                    continue
                }
                value = regexReplace(value, pattern: pattern, replacement: replacement)
                k += 2
            }
            return .text(value)
        }

        return evalSelector(rule, ctx: ctx, json: json)
    }

    private static func regexReplace(_ text: String, pattern: String, replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        // Legado 里 `##a##b` 的 b 是替换串，`$1` 这类反向引用要生效
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    // MARK: - 选择器

    /// 单个选择器：`$.json.path` 或裸字段名（按 JSON 处理）。HTML/XPath 在本期范围外。
    private static func evalSelector(_ selector: String, ctx: RuleContext, json: Any? = nil) -> RuleValue {
        let s = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .text("") }

        // `@get:{key}` / `@put:{...}` 抽出来单处理
        if s.hasPrefix("@get:") {
            let key = String(s.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            return .text(ctx.vars[key] ?? "")
        }

        // 形如 `body.books` 或 `$.body.books` 的 JSON 路径
        let candidates = [s, s.hasPrefix("$") ? String(s.dropFirst()) : "$." + s]
        for cand in candidates {
            if let obj = json ?? parseJSON(ctx.body) {
                let nodes = JsonPath.query(obj, cand.hasPrefix("$") ? cand : "$." + cand)
                if !nodes.isEmpty {
                    if nodes.count == 1, let str = nodes[0] as? String { return .text(str) }
                    return .text(nodes.map { scalarString($0) }.joined(separator: "\n"))
                }
            }
        }

        // 裸字段名但 body 不是 JSON → 当纯文本返回（`##regex` 的输入常见）
        if !ctx.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return .text(s) }
        return .text("")
    }
}
