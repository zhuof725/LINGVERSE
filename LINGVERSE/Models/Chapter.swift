import Foundation

/// 章节模型（空壳占位）
/// 时长与音频地址留空，真实数据接入后再填充。
struct Chapter: Identifiable, Hashable {
    let id: UUID
    var title: String
    var duration: TimeInterval
    var audioURL: URL?

    init(
        id: UUID = UUID(),
        title: String,
        duration: TimeInterval = 0,
        audioURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.audioURL = audioURL
    }
}
