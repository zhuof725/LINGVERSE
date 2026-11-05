import Foundation
import Combine

/// 书源运行诊断日志。
///
/// 书源调试最难受的就是「搜不到东西但不知道卡在哪」。
/// 每一层（请求 / 规则 / JS）都往这里写一行带标签的记录，
/// 界面上按顺序铺开就能一眼看出是哪一步断了。
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let at = Date()
        let tag: String
        let message: String

        var line: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "\(f.string(from: at)) [\(tag)] \(message)"
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let limit = 300
    private let lock = NSLock()

    private init() {}

    func add(_ tag: String, _ message: String) {
        let entry = Entry(tag: tag, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    var snapshot: String {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.line).joined(separator: "\n")
    }
}

/// bookon 里用 `DebugLog` 这个名字，保留别名方便两边代码对照阅读。
typealias DebugLog = Diagnostics
