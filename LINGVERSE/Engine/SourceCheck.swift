import Foundation

/// 书源体检。
///
/// 导入一堆源之后最实际的问题是「哪些还能用」。
/// 这里对每条源做一次最小闭环：搜索有没有结果 → 第一条能不能出目录。
/// 只做两步，不验播放地址（那要额外抓详情页，慢且容易被限流）。
enum SourceCheck {

    struct Result: Identifiable {
        let id = UUID()
        let sourceName: String
        let sourceId: String
        /// 搜索耗时（秒）
        var searchSeconds: Double = 0
        var searchCount: Int = 0
        var tocCount: Int = 0
        var failure: String?

        var status: Status {
            if let failure { return .failed(failure) }
            if searchCount == 0 { return .noResult }
            if tocCount == 0 { return .tocFailed }
            return .ok
        }

        enum Status {
            case ok, noResult, tocFailed, failed(String)

            var symbol: String {
                switch self {
                case .ok: return "checkmark.circle.fill"
                case .noResult: return "questionmark.circle.fill"
                case .tocFailed: return "exclamationmark.triangle.fill"
                case .failed: return "xmark.circle.fill"
                }
            }

            var text: String {
                switch self {
                case .ok: return "可用"
                case .noResult: return "搜不到"
                case .tocFailed: return "目录失败"
                case .failed: return "失败"
                }
            }
        }
    }

    /// 体检一条源。用固定关键字（有声音频源基本都能搜到「三体」或「小说」）。
    static func check(_ source: BookSource, keyword: String = "三体") async -> Result {
        var result = Result(sourceName: source.bookSourceName, sourceId: source.id)

        let start = Date()
        let found: [SourcePipeline.SearchResult]
        do {
            found = try await Task.detached(priority: .utility) {
                try SourcePipeline.shared.search(keyword, source: source)
            }.value
        } catch {
            result.failure = error.localizedDescription
            result.searchSeconds = Date().timeIntervalSince(start)
            return result
        }
        result.searchSeconds = Date().timeIntervalSince(start)
        result.searchCount = found.count

        guard let first = found.first else { return result }

        do {
            let (detail, chapters) = try await Task.detached(priority: .utility) {
                let info = try SourcePipeline.shared.bookInfo(first.bookUrl, source: source, hint: first)
                let list = try SourcePipeline.shared.toc(info, source: source)
                return (info, list)
            }.value
            result.tocCount = chapters.count
            if chapters.isEmpty, detail.tocUrl == nil {
                result.failure = "没有 tocUrl，且 bookUrl 不是目录页"
            }
        } catch {
            result.failure = error.localizedDescription
        }
        return result
    }

    /// 批量体检。串行执行 —— 并发容易触发书站限流，反而全是失败。
    static func checkAll(_ sources: [BookSource], keyword: String,
                         progress: @escaping @MainActor (Result) -> Void) async {
        for source in sources {
            let result = await check(source, keyword: keyword)
            await MainActor.run { progress(result) }
        }
    }
}
