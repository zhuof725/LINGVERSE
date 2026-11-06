import Foundation

/// Legado 规则的词法切分。
///
/// 书源规则里 `##`（正则替换）、`&&`（交集/兜底）、`||`（备用）都是分隔符，
/// 但当它们出现在字符串字面量或括号里时并不是分隔符。扫描时跟踪引号与括号深度，
/// 只在最外层切分。
enum RuleScanner {

    struct Split {
        let parts: [String]
        let separator: String?
        let valid: Bool
    }

    /// 按给定运算符切分。`valid == false` 表示引号或括号不配对，调用方应把整串当普通规则处理。
    static func split(_ text: String, by operators: [String]) -> Split {
        let result = scan(text, operators)
        guard result.valid else { return Split(parts: [text], separator: nil, valid: false) }
        var parts: [String] = []
        var start = text.startIndex
        for hit in result.hits {
            parts.append(String(text[start..<hit.range.lowerBound]))
            start = hit.range.upperBound
        }
        parts.append(String(text[start...]))
        return Split(parts: parts, separator: result.hits.first?.token, valid: true)
    }

    /// 第一个位于最外层的运算符位置。
    static func firstTopLevel(_ text: String, _ tokens: [String]) -> Range<String.Index>? {
        scan(text, tokens, firstOnly: true).hits.first?.range
    }

    private static func scan(_ text: String, _ tokens: [String], firstOnly: Bool = false)
        -> (hits: [(range: Range<String.Index>, token: String)], valid: Bool) {
        var hits: [(range: Range<String.Index>, token: String)] = []
        var stack: [Character] = []
        var quote: Character?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
                i = text.index(after: i)
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                quote = c
                i = text.index(after: i)
                continue
            }
            if stack.isEmpty, let token = tokens.first(where: { text[i...].hasPrefix($0) }) {
                let end = text.index(i, offsetBy: token.count)
                hits.append((i..<end, token))
                if firstOnly { return (hits, true) }
                i = end
                continue
            }
            if let close = closing(c) {
                stack.append(close)
            } else if c == ")" || c == "]" || c == "}" {
                guard stack.last == c else { return (hits, false) }
                stack.removeLast()
            }
            i = text.index(after: i)
        }
        return (hits, stack.isEmpty && quote == nil)
    }

    private static func closing(_ c: Character) -> Character? {
        switch c {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        default: return nil
        }
    }

    /// 从 `start` 处的开括号找到配对的闭括号（含两端）。
    static func balancedRange(_ text: String, at start: String.Index) -> Range<String.Index>? {
        guard start < text.endIndex, let endChar = closing(text[start]) else { return nil }
        var stack: [Character] = [endChar]
        var quote: Character?
        var i = text.index(after: start)
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if let close = closing(c) {
                stack.append(close)
            } else if c == ")" || c == "]" || c == "}" {
                guard stack.last == c else { return nil }
                stack.removeLast()
                if stack.isEmpty { return start..<text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// 脱引号：`"abc"` / `'abc'` → `abc`。不是合法引号字面量时返回 nil。
    /// 双引号走 JSON 解码（能正确处理 \u4e2d 这类转义），单引号手工处理。
    static func unquote(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = t.first, (q == "\"" || q == "'"), t.count >= 2, t.last == q else { return nil }
        if q == "\"", let data = t.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return value
        }
        var result = ""
        var escaped = false
        for c in t.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"", "'", "/": result.append(c)
                default: result.append("\\"); result.append(c)
                }
                escaped = false
            } else if c == "\\" { escaped = true }
            else if c == q { return nil }
            else { result.append(c) }
        }
        return escaped ? nil : result
    }

    /// 剥掉规则里的 js 前缀，返回脚本正文。`@js:a` / `<js>a` / `@js:\na` 三种写法等价。
    static func scriptBody(_ rule: String) -> String? {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("@js:") {
            // @js: 可能也带 </js> 闭合（真实书源的 tocUrl 就这么写）
            if let end = t.range(of: "</js>", options: .backwards) {
                return String(t[t.index(t.startIndex, offsetBy: 4)..<end.lowerBound])
            }
            return String(t.dropFirst(4))
        }
        if t.hasPrefix("<js>") {
            // 必须同时剥掉结尾的 </js>：只 dropFirst(4) 会把闭合标签
            // 留在脚本里，JSContext 直接报语法错误，
            // 而错误又被上层 catch 成"脚本返回空"。
            if let end = t.range(of: "</js>", options: .backwards) {
                let body = String(t[t.index(t.startIndex, offsetBy: 4)..<end.lowerBound])
                let rest = String(t[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                // 后面还跟着 JSONPath 的（如 </js>$[*]）不算纯脚本
                return rest.isEmpty ? body : nil
            }
            return String(t.dropFirst(4))
        }
        return nil
    }
}
