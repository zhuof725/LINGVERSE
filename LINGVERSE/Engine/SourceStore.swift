import Foundation
import Combine

/// 书源仓库：负责导入、导出、持久化、启用/禁用。
///
/// 存储用 Application Support 下的单个 JSON 文件，不做数据库 ——
/// 书源数量一般是几十条，全量读写完全够用，还便于用户直接拷文件备份。
@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    @Published private(set) var sources: [BookSource] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sources.json")
        load()
    }

    // MARK: - 增删改

    func upsert(_ list: [BookSource]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for source in list {
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl
                                                 && $0.bookSourceName == source.bookSourceName }) {
                sources[idx] = source
                updated += 1
            } else {
                sources.append(source)
                added += 1
            }
        }
        if added + updated > 0 { save() }
        return (added, updated)
    }

    func remove(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        save()
    }

    func setEnabled(_ enabled: Bool, for source: BookSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx].enabled = enabled
        save()
    }

    /// 启用的音频源。文本源在 LINGVERSE 里跑不出音频，直接过滤掉。
    var audioSources: [BookSource] {
        sources.filter { $0.isEnabled && $0.isAudio }
    }

    var allEnabled: [BookSource] {
        sources.filter(\.isEnabled)
    }

    // MARK: - 导入

    /// 从 JSON 文本导入。既接受数组也接受单个对象（Legado 导出两种都有）。
    /// 返回解析成功但被我方规则识别为「文本源」的数量，用于提示。
    @discardableResult
    func importJSON(_ text: String) throws -> ImportReport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }
        guard let data = trimmed.data(using: .utf8) else { throw ImportError.notJSON }

        let decoder = JSONDecoder()
        var parsed: [BookSource] = []

        if let list = try? decoder.decode([BookSource].self, from: data) {
            parsed = list
        } else if let single = try? decoder.decode(BookSource.self, from: data) {
            parsed = [single]
        } else {
            throw ImportError.badFormat
        }

        // 完全没识别出规则的，多半不是书源文件
        parsed = parsed.filter { $0.bookSourceUrl.isEmpty == false || $0.bookSourceName.isEmpty == false }
        guard !parsed.isEmpty else { throw ImportError.badFormat }

        let result = upsert(parsed)
        let textOnly = parsed.filter { !$0.isAudio }
        return ImportReport(
            total: parsed.count,
            added: result.added,
            updated: result.updated,
            textOnly: textOnly.count,
            textOnlyNames: textOnly.prefix(3).map(\.bookSourceName)
        )
    }

    struct ImportReport {
        var total: Int
        var added: Int
        var updated: Int
        /// 类型是文本（bookSourceType != 1）的源数量。LINGVERSE 只跑音频源。
        var textOnly: Int
        var textOnlyNames: [String]

        var summary: String {
            var parts = ["共 \(total) 条，新增 \(added)，更新 \(updated)"]
            if textOnly > 0 {
                let names = textOnlyNames.joined(separator: "、")
                let more = textOnly > textOnlyNames.count ? " 等" : ""
                parts.append("其中 \(textOnly) 条是文本源（\(names)\(more)），听书用不到，已保存但不会出现在搜索里")
            }
            return parts.joined(separator: "；")
        }
    }

    enum ImportError: LocalizedError {
        case empty, notJSON, badFormat

        var errorDescription: String? {
            switch self {
            case .empty: return "内容为空"
            case .notJSON: return "不是合法的 JSON 文本"
            case .badFormat: return "不是 Legado 书源格式（既不是数组也不是对象）"
            }
        }
    }

    // MARK: - 导出

    func exportJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(sources)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        sources = (try? JSONDecoder().decode([BookSource].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
