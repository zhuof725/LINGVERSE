import Foundation

/// 从规则结果里把音频地址抠出来。
///
/// 音频源的 `ruleContent.content` 返回值五花八门：
/// 直接一条 mp3 链接、JSON `{"url": "..."}`、数组、甚至一段带引号的 HTML。
/// 这里按「最可能」的顺序逐层尝试，解析不出返回空数组而不是瞎猜。
enum AudioURL {
    /// 常见音频扩展名（小写、不带点）。
    static let extensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "m4b", "opus", "wma", "amr", "mp4",
    ]

    /// 是否音频文件直链。忽略查询参数与锚点，只看路径扩展名。
    static func isDirect(_ raw: String) -> Bool {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }
        let path = url.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
        guard path.contains("."), let ext = path.split(separator: ".").last else { return false }
        return extensions.contains(String(ext))
    }

    /// 是否可播放地址：http(s) 且不含空格。
    /// 很多音频接口没有扩展名（`/getAudio?id=123`），不能只认扩展名。
    static func isPlayable(_ raw: String) -> Bool {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://"), !url.contains(" ") else { return false }
        // 明显是网页/接口文档的排除掉
        let lower = url.lowercased()
        let pageMarks = [".html", ".htm", ".php", ".asp", ".aspx", ".jsp", ".shtml",
                         ".json", ".xml", ".txt", ".css", ".js"]
        return !pageMarks.contains { lower.contains($0) }
    }

    /// 解析规则输出 → 地址数组（去重、保序、补全相对路径）。
    static func parse(_ raw: String, base: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // 1) JSON：数组 / 带 url 字段的对象
        if text.hasPrefix("[") || text.hasPrefix("{"), let data = text.data(using: .utf8) {
            if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                let urls = jsonURLs(obj)
                if !urls.isEmpty { return normalize(urls, base: base) }
            }
        }
        // 2) 整串就是一个地址
        if isPlayable(text) { return normalize([text], base: base) }
        // 3) 逐行找第一个音频直链
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for line in lines {
            let candidate = String(line)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if isDirect(candidate) { return normalize([candidate], base: base) }
        }
        // 4) 逐行找第一个可播放地址
        for line in lines {
            let candidate = String(line)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if isPlayable(candidate) { return normalize([candidate], base: base) }
        }
        return []
    }

    /// 从 JSON 对象里递归找地址。常见字段名优先，找不到再翻一层容器字段。
    static func jsonURLs(_ object: Any, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        if let s = object as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return isPlayable(t) ? [t] : []
        }
        if let list = object as? [Any] {
            return list.flatMap { jsonURLs($0, depth: depth + 1) }
        }
        guard let map = object as? [String: Any] else { return [] }

        let directKeys = ["url", "audioUrl", "audio_url", "playUrl", "play_url",
                          "src", "audio", "fileUrl", "file_url", "mp3", "m4a"]
        var out: [String] = []
        for key in directKeys {
            if let value = map[key] { out.append(contentsOf: jsonURLs(value, depth: depth + 1)) }
        }
        if !out.isEmpty { return out }
        for key in ["data", "list", "urls", "audioList", "result", "items", "sources"] {
            if let value = map[key] { out.append(contentsOf: jsonURLs(value, depth: depth + 1)) }
        }
        return out
    }

    private static func normalize(_ urls: [String], base: String) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { raw -> String? in
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if t.hasPrefix("//") { t = "https:" + t }
            else if !t.lowercased().hasPrefix("http"), let b = URL(string: base),
                    let resolved = URL(string: t, relativeTo: b)?.absoluteString { t = resolved }
            guard t.lowercased().hasPrefix("http") else { return nil }
            return seen.insert(t).inserted ? t : nil
        }
    }
}
