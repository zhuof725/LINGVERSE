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
    ///
    /// 真实世界的书源分享长这样，全都得吃下去：
    /// - 干净的 JSON 数组 / 对象
    /// - 开头带一段说明文字，中间才是 JSON（`bookSourceUrl` 之后截取）
    /// - 整段 Base64（很多分享站就是这么给的）
    /// - 多个对象用换行拼接（一次导入一串）
    @discardableResult
    func importJSON(_ text: String) throws -> ImportReport {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ImportError.empty }

        let candidates = JSONExtractor.candidates(from: raw)
        guard !candidates.isEmpty else { throw ImportError.notJSON }

        var parsed: [BookSource] = []
        var lastError: Error = ImportError.badFormat

        for candidate in candidates {
            do {
                parsed = try decodeSources(from: candidate)
                if !parsed.isEmpty { break }
            } catch {
                lastError = error
            }
        }
        guard !parsed.isEmpty else { throw lastError }

        // 彻底没识别出源信息的（既无 url 又无 name）是脏数据
        parsed = parsed.filter { !$0.bookSourceUrl.isEmpty || !$0.bookSourceName.isEmpty }
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

    /// 解码成书源数组。支持单一 JSON、数组、以及「多个 JSON 对象换行拼接」。
    private func decodeSources(from text: String) throws -> [BookSource] {
        let decoder = JSONDecoder()
        guard let data = text.data(using: .utf8) else { throw ImportError.notJSON }

        if let list = try? decoder.decode([BookSource].self, from: data), !list.isEmpty {
            return list
        }
        if let single = try? decoder.decode(BookSource.self, from: data) {
            return [single]
        }
        // 换行拼接的多个对象：按行拆，逐行解
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let dict = object as? [String: Any],
           dict["bookSourceUrl"] != nil || dict["bookSourceName"] != nil {
            // 已经是字典但没解成 BookSource，说明字段类型有严重问题
            if let re = try? JSONSerialization.data(withJSONObject: [dict]),
               let list = try? decoder.decode([BookSource].self, from: re) {
                return list
            }
        }
        // 逐行尝试（一行一个书源）
        var collected: [BookSource] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { continue }
            if let d = t.data(using: .utf8),
               let one = try? decoder.decode(BookSource.self, from: d) {
                collected.append(one)
            }
        }
        if !collected.isEmpty { return collected }
        throw ImportError.badFormat
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
