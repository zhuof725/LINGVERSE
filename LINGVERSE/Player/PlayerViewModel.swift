import SwiftUI
import Combine

/// 全局播放视图模型（空壳：状态占位，引擎待接）
/// 由 LINGVERSEApp 作为 @StateObject 注入环境，各页面共享。

final class PlayerViewModel: ObservableObject {
    @Published var currentBook: Book?
    @Published var currentChapter: Chapter?
    @Published var state: PlaybackState = .idle
    @Published var progress: Double = 0

    // 播放引擎（空壳：协议已定义，实现留待后续）
    private var engine: AudioPlaying?

    /// 加载一本书并准备播放（空壳：仅更新状态，不真正播放）。
    func load(book: Book, chapter: Chapter? = nil) {
        currentBook = book
        currentChapter = chapter ?? book.chapters.first
        state = .idle
        progress = 0

        // TODO: 创建真实引擎（实现 AudioPlaying），调用 AudioSessionManager.activate()
        //       与 NowPlayingManager.update(...)。
    }

    /// 播放/暂停切换（空壳：仅翻转状态，供 UI 演示）。
    func togglePlay() {
        switch state {
        case .playing:
            state = .paused
        default:
            state = .playing
        }
        // TODO: 引擎 play()/pause()，并同步 NowPlayingManager.update(...)。
    }
}
