import Foundation

/// 书架上的书 / 正在播放的书。
///
/// 和原来的占位 `Book` 不同，这里的 `bookUrl` 是稳定主键 ——
/// 书源给的地址才是身份，UUID 每次启动都变，存书架会重复。
struct LBook: Identifiable, Hashable, Codable {
    var id: String { bookUrl }

    var bookUrl: String
    var name: String
    var author: String
    var intro: String?
    var kind: String?
    var coverUrl: String?
    var lastChapter: String?
    /// 书源标识（BookSource.id），用来找回规则。
    var sourceId: String
    var sourceName: String
    var addedAt: Date = Date()
}

/// 章节。`url` 是书源里的章节地址，可能每次抓取都变（带签名），
/// 所以定位当前章节用 `index`，不用 `url`。
struct LChapter: Identifiable, Hashable, Codable {
    var id: String { "\(index)#\(title)" }

    var index: Int
    var title: String
    var url: String
}

extension LBook {
    init(detail: BookDetail, sourceId: String, sourceName: String) {
        self.bookUrl = detail.bookUrl
        self.name = detail.name
        self.author = detail.author
        self.intro = detail.intro
        self.kind = detail.kind
        self.coverUrl = detail.coverUrl
        self.lastChapter = detail.lastChapter
        self.sourceId = sourceId
        self.sourceName = sourceName
    }
}
