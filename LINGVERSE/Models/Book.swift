import Foundation

/// 书籍模型（空壳占位）
/// 字段仅够支撑界面骨架，后续可扩展封面、简介、连载状态等。
struct Book: Identifiable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var category: String
    var chapters: [Chapter]

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        category: String = "",
        chapters: [Chapter] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.category = category
        self.chapters = chapters
    }
}
