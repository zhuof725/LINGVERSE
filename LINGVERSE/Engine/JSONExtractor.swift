import Foundation

/// 从一段「用户粘贴进来的东西」里把 JSON 抠出来。
///
/// 书源分享的形态比想象中杂：
/// 干净 JSON、带解说词的 JSON、Base64、甚至 JSON 前后各有一段网址。
/// 这里按可能性从高到低产出候选文本，让调用方逐个尝试解析。
enum JSONExtractor {

    static func candidates(from raw: String) -> [String] {
        var out: [String] = []
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) 本身就是 JSON
        if text.hasPrefix("{") || text.hasPrefix("[") {
            out.append(text)
            // 1b) 末尾可能粘了多余内容：截到配对的最后一个括号
            if let trimmed = balancedPrefix(text) { out.append(trimmed) }
        }

        // 2) Base64：去掉空白后只含 base64 字符，且能解出 JSON
        let compact = text.filter { !$0.isWhitespace }
        if compact.count > 64, compact.range(of: "^[A-Za-z0-9+/=_-]+$", options: .regularExpression) != nil {
            let normalized = compact
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            if let data = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters),
               let decoded = String(data: data, encoding: .utf8) {
                let t = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("{") || t.hasPrefix("[") { out.append(t) }
            }
        }

        // 3) 文本里夹着 JSON：从第一个 { 或 [ 开始截取
        if let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            let slice = String(text[start...])
            if let balanced = balancedPrefix(slice) { out.append(balanced) }
            if slice != text { out.append(slice) }
        }

        // 去重、保序
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 从字符串开头截到括号配对的最后一个位置。
    /// 用于处理「JSON 后面还跟了别的文字」的情况。
    static func balancedPrefix(_ text: String) -> String? {
        guard let first = text.first, first == "{" || first == "[" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var lastBalancedEnd: String.Index?

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" || c == "[" {
                    depth += 1
                } else if c == "}" || c == "]" {
                    depth -= 1
                    if depth == 0 {
                        lastBalancedEnd = text.index(after: i)
                        // 继续往后看，可能是拼接的第二个 JSON 数组
                        let rest = text[lastBalancedEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
                        if rest.isEmpty { break }
                    }
                    if depth < 0 { return nil }
                }
            }
            i = text.index(after: i)
        }

        guard let end = lastBalancedEnd else { return nil }
        return String(text[text.startIndex..<end])
    }
}
