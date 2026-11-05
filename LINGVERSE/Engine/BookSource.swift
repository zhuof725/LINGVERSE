import Foundation

/// Legado 书源（BookSource）的最小可用子集。
///
/// 字段名严格照抄 Legado / bookon，这样同一份书源 JSON 在两个 App 之间可以直接互相导入。
/// 没有建模的字段会落在 `extra` 里原样保留 —— 导入再导出不能丢内容，
/// 否则用户在 LINGVERSE 里编辑过的源就废了。
struct BookSource: Codable, Hashable, Identifiable {
    var id: String { bookSourceUrl + "##" + bookSourceName }

    var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    /// 0 = 文本；1 = 音频。LINGVERSE 只跑音频源，但保留字段以便识别。
    var bookSourceType: Int?
    var bookSourceComment: String?
    var enabled: Bool?
    var header: String?
    var jsLib: String?
    var searchUrl: String?
    var exploreUrl: String?
    var bookUrlPattern: String?
    var ruleSearch: SearchRule?
    var ruleExplore: SearchRule?
    var ruleBookInfo: BookInfoRule?
    var ruleToc: TocRule?
    var ruleContent: ContentRule?
    var lastUpdateTime: Int64?

    /// 未建模字段，原样保留。
    var extra: [String: JSONValue] = [:]

    var isAudio: Bool { bookSourceType == 1 }
    var isEnabled: Bool { enabled ?? true }

    // MARK: Codable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookSourceComment
        case enabled, header, jsLib, searchUrl, exploreUrl, bookUrlPattern
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent, lastUpdateTime
    }

    init(bookSourceUrl: String, bookSourceName: String, bookSourceType: Int? = 1) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.bookSourceType = bookSourceType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 源文件里 bookSourceUrl 偶尔是数字或缺省，这里全部按「能读就读，读不到给空」处理，
        // 否则一条坏源会让整份导入 JSON 解析失败。
        bookSourceUrl = (try? c.decode(String.self, forKey: .bookSourceUrl)) ?? ""
        bookSourceName = (try? c.decode(String.self, forKey: .bookSourceName)) ?? bookSourceUrl
        bookSourceGroup = try? c.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        bookSourceType = Self.lenientInt(c, .bookSourceType)
        bookSourceComment = try? c.decodeIfPresent(String.self, forKey: .bookSourceComment)
        enabled = Self.lenientBool(c, .enabled)
        header = try? c.decodeIfPresent(String.self, forKey: .header)
        jsLib = try? c.decodeIfPresent(String.self, forKey: .jsLib)
        searchUrl = try? c.decodeIfPresent(String.self, forKey: .searchUrl)
        exploreUrl = try? c.decodeIfPresent(String.self, forKey: .exploreUrl)
        bookUrlPattern = try? c.decodeIfPresent(String.self, forKey: .bookUrlPattern)
        ruleSearch = try? c.decodeIfPresent(SearchRule.self, forKey: .ruleSearch)
        ruleExplore = try? c.decodeIfPresent(SearchRule.self, forKey: .ruleExplore)
        ruleBookInfo = try? c.decodeIfPresent(BookInfoRule.self, forKey: .ruleBookInfo)
        ruleToc = try? c.decodeIfPresent(TocRule.self, forKey: .ruleToc)
        ruleContent = try? c.decodeIfPresent(ContentRule.self, forKey: .ruleContent)
        lastUpdateTime = try? c.decodeIfPresent(Int64.self, forKey: .lastUpdateTime)

        // 未建模字段原样收进 extra
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        var rest: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let value = try? dynamic.decode(JSONValue.self, forKey: key) { rest[key.stringValue] = value }
        }
        extra = rest
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bookSourceUrl, forKey: .bookSourceUrl)
        try c.encode(bookSourceName, forKey: .bookSourceName)
        try c.encodeIfPresent(bookSourceGroup, forKey: .bookSourceGroup)
        try c.encodeIfPresent(bookSourceType, forKey: .bookSourceType)
        try c.encodeIfPresent(bookSourceComment, forKey: .bookSourceComment)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(jsLib, forKey: .jsLib)
        try c.encodeIfPresent(searchUrl, forKey: .searchUrl)
        try c.encodeIfPresent(exploreUrl, forKey: .exploreUrl)
        try c.encodeIfPresent(bookUrlPattern, forKey: .bookUrlPattern)
        try c.encodeIfPresent(ruleSearch, forKey: .ruleSearch)
        try c.encodeIfPresent(ruleExplore, forKey: .ruleExplore)
        try c.encodeIfPresent(ruleBookInfo, forKey: .ruleBookInfo)
        try c.encodeIfPresent(ruleToc, forKey: .ruleToc)
        try c.encodeIfPresent(ruleContent, forKey: .ruleContent)
        try c.encodeIfPresent(lastUpdateTime, forKey: .lastUpdateTime)

        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in extra {
            guard let k = DynamicKey(stringValue: key) else { continue }
            try dynamic.encode(value, forKey: k)
        }
    }

    static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))

    // MARK: 宽松解码

    private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    private static func lenientBool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let v = try? c.decodeIfPresent(Bool.self, forKey: key) { return v }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes"].contains(s.lowercased())
        }
        return nil
    }
}

// MARK: - 规则结构

struct SearchRule: Codable, Hashable {
    var checkKeyWord: String?
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
}

struct BookInfoRule: Codable, Hashable {
    var `init`: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var coverUrl: String?
    var tocUrl: String?
    var wordCount: String?
}

struct TocRule: Codable, Hashable {
    var preUpdateJs: String?
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var formatJs: String?
    var isVolume: String?
    var isVip: String?
    var updateTime: String?
    var nextTocUrl: String?
}

struct ContentRule: Codable, Hashable {
    var content: String?
    var title: String?
    var nextContentUrl: String?
    var webJs: String?
    var sourceRegex: String?
    var replaceRegex: String?
    var subContent: String?
}

// MARK: - 动态 key / 任意 JSON

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// 原样保存未建模字段用。只保证「能装回去」，不追求类型精确。
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v):
            // 整数不要编码成 1790057528250.0
            if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
