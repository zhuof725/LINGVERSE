import Foundation
import Combine

/// 书架。持久化到 Application Support，全量读写。
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var books: [LBook] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL) {
            books = (try? JSONDecoder().decode([LBook].self, from: data)) ?? []
        }
    }

    func contains(name: String, author: String) -> Bool {
        books.contains { $0.name == name && $0.author == author }
    }

    func contains(bookUrl: String) -> Bool {
        books.contains { $0.bookUrl == bookUrl }
    }

    func add(_ book: LBook) {
        guard !books.contains(where: { $0.bookUrl == book.bookUrl }) else { return }
        books.insert(book, at: 0)
        save()
    }

    func remove(name: String, author: String) {
        books.removeAll { $0.name == name && $0.author == author }
        save()
    }

    func remove(_ book: LBook) {
        books.removeAll { $0.bookUrl == book.bookUrl }
        save()
    }

    func remove(at offsets: IndexSet) {
        books.remove(atOffsets: offsets)
        save()
    }

    /// 按书名+作者找到书架里的对应条目（搜索结果和书架的 bookUrl 可能不同）。
    func match(name: String, author: String) -> LBook? {
        books.first { $0.name == name && $0.author == author }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
