import Foundation

/// 一个「带请求参数的 URL」。
///
/// Legado 的规则除了返回 URL，还能返回 `url, {"method":"POST","body":...,"headers":{...}}`，
/// 甚至只返回 body 由框架去 POST。真实书源（尤其番茄这类 API 型）几乎全靠这个约定。
struct RequestSpec {
    var url: String
    var method: String = "GET"
    var body: String?
    var headers: [String: String] = [:]

    /// 从规则返回值里解析出 RequestSpec。
    ///
    /// 接受的形态：
    /// - `https://a/b`
    /// - `https://a/b, {"method":"POST","body":"...","headers":{...}}`
    /// - `https://a/b\n{...}`（换行分隔，部分源这么写）
    /// - 纯 URL 后面跟了别的说明文字
    static func parse(_ raw: String, base: String) -> RequestSpec? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1) 找逗号 / 换行后接 { 的位置：前半是 URL，后半是 options
        if let split = splitURLAndOptions(text) {
            var spec = RequestSpec(url: split.url)
            apply(split.options, to: &spec)
            spec.url = normalize(spec.url, base: base)
            return spec.url.isEmpty ? nil : spec
        }

        // 2) 纯 URL
        let url = normalize(text, base: base)
        return url.isEmpty ? nil : RequestSpec(url: url)
    }

    private static func splitURLAndOptions(_ text: String) -> (url: String, options: String)? {
        // 逗号分隔：`url, {json}`
        if let brace = text.firstIndex(of: "{") {
            let head = String(text[text.startIndex..<brace])
            let tail = String(text[brace...])
            let trimmedHead = head.trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\r\t"))
            // head 必须看起来像 URL，且 tail 是合法 JSON
            if trimmedHead.lowercased().hasPrefix("http"),
               tail.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
               JSONSerialization.isValidJSONObjectOrFragment(tail) {
                return (trimmedHead, tail)
            }
        }
        return nil
    }

    private static func apply(_ optionsJSON: String, to spec: inout RequestSpec) {
        guard let data = optionsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let method = obj["method"] as? String { spec.method = method.uppercased() }
        if let body = obj["body"] as? String { spec.body = body }
        else if let body = obj["body"] { spec.body = String(describing: body) }

        if let headers = obj["headers"] as? [String: Any] {
            for (k, v) in headers { spec.headers[k] = (v as? String) ?? String(describing: v) }
        }
        // Legado 还有 `charset` / `retry` 等，这里不关心
    }

    /// 补全相对地址，并去掉行尾多余标点。
    static func normalize(_ raw: String, base: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 规则末尾常带逗号分号
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        guard !t.isEmpty else { return "" }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
        if t.hasPrefix("//") { return "https:" + t }
        guard let baseURL = URL(string: base) else { return "" }
        return URL(string: t, relativeTo: baseURL)?.absoluteString ?? ""
    }
}

private extension JSONSerialization {
    /// 判断一段文本是不是 JSON 对象/数组（允许片段）。
    static func isValidJSONObjectOrFragment(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}
