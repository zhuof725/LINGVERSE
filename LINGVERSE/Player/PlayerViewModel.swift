import SwiftUI
import Combine

/// 全局播放视图模型。把书源、播放引擎、锁屏信息串起来。
///
/// 进度用两个字段区分，避免上一版把 0…1 的比例和秒数混用：
/// - `progressRatio` 给 Slider 用（0…1）
/// - `currentTime` / `duration` 给文本和锁屏用（秒）
@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var currentBook: LBook?
    @Published private(set) var currentChapter: LChapter?
    @Published private(set) var state: PlaybackState = .idle
    @Published var progressRatio: Double = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var chapters: [LChapter] = []

    /// 是否正在拖动进度条。拖动时不能被周期性进度回调覆盖。
    @Published var isScrubbing = false
    private var scrubbingValue: Double = 0

    private var engine: AudioPlaying?

    var isPlaying: Bool { state == .playing || state == .buffering }

    init() {
        AudioSessionManager.activate()
        NowPlayingManager.setupRemoteCommands(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seekToSeconds: { [weak self] seconds in self?.seek(toSeconds: seconds) },
            skipBy: { [weak self] delta in self?.skip(by: delta) }
        )
    }

    // MARK: - 载入

    /// 载入一章并立即开始播放。`audioURL` 已由书源流水线解析完成。
    func load(book: LBook, chapter: LChapter, audioURL: URL, allChapters: [LChapter]) {
        currentBook = book
        currentChapter = chapter
        chapters = allChapters
        currentTime = 0
        duration = 0
        progressRatio = 0

        let engine = makeEngine()
        engine.load(url: audioURL)

        // 先激活会话再播：晚于 play() 会被系统判定为前台音频，切后台就停
        AudioSessionManager.activate()
        engine.play()
        updateNowPlaying()
    }

    // MARK: - 控制

    func play() {
        guard engine != nil else { return }
        AudioSessionManager.activate()
        engine?.play()
        updateNowPlaying()
    }

    func pause() {
        engine?.pause()
        updateNowPlaying()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard let current = currentChapter,
              let idx = chapters.firstIndex(where: { $0.index == current.index }),
              idx + 1 < chapters.count else { return }
        playChapter(at: idx + 1)
    }

    func previous() {
        guard let current = currentChapter,
              let idx = chapters.firstIndex(where: { $0.index == current.index }),
              idx > 0 else { return }
        playChapter(at: idx - 1)
    }

    func seek(toRatio ratio: Double) {
        let clamped = min(max(ratio, 0), 1)
        progressRatio = clamped
        scrubbingValue = clamped
        guard duration > 0 else { return }
        seek(toSeconds: clamped * duration)
    }

    /// 按秒跳转（锁屏进度条拖拽、Siri 快进）。
    func seek(toSeconds seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        engine?.seek(to: clamped)
        currentTime = clamped
        progressRatio = clamped / duration
        updateNowPlaying()
    }

    /// 相对跳转（±15 秒）。
    func skip(by delta: TimeInterval) {
        guard duration > 0 else { return }
        seek(toSeconds: currentTime + delta)
    }

    /// Slider 拖动开始 / 结束。拖动期间不让引擎进度回调覆盖滑块。
    func beginScrubbing() {
        isScrubbing = true
    }

    func endScrubbing() {
        isScrubbing = false
        seek(toRatio: scrubbingValue)
    }

    // MARK: - 切章

    private func playChapter(at index: Int) {
        guard let book = currentBook, index >= 0, index < chapters.count else { return }
        let chapter = chapters[index]
        guard let source = SourceStore.shared.sources.first(where: { $0.id == book.sourceId }) else {
            Diagnostics.shared.add("player", "找不到书源 \(book.sourceId)")
            return
        }

        let detail = BookDetail(
            bookUrl: book.bookUrl, name: book.name, author: book.author,
            intro: book.intro, kind: book.kind, coverUrl: book.coverUrl,
            lastChapter: book.lastChapter, wordCount: nil, tocUrl: nil
        )
        let sourceChapter = SourceChapter(
            index: chapter.index, title: chapter.title, url: chapter.url
        )

        Task {
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try SourcePipeline.shared.playURLs(
                        chapter: sourceChapter, detail: detail, source: source)
                }.value
                guard let url = urls.first.flatMap(URL.init(string:)) else {
                    Diagnostics.shared.add("player", "第 \(chapter.title) 章无音频地址")
                    return
                }
                currentChapter = chapter
                currentTime = 0
                duration = 0
                progressRatio = 0
                let engine = makeEngine()
                engine.load(url: url)
                AudioSessionManager.activate()
                engine.play()
            } catch {
                Diagnostics.shared.add("player", "切章失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 引擎

    private func makeEngine() -> AudioPlaying {
        // 每次换章都换引擎：AVPlayer 换 item 时旧观察者容易残留，
        // 干脆一个章节一个引擎，代价可以忽略。
        let engine = AVPlayerEngine()
        engine.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                self?.updateNowPlaying()
            }
        }
        engine.onProgress = { [weak self] time, total in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time
                if total > 0 { self.duration = total }
                if !self.isScrubbing, self.duration > 0 {
                    self.progressRatio = min(max(time / self.duration, 0), 1)
                }
                self.updateNowPlaying()
            }
        }
        // engine 的静态类型本来就是 AVPlayerEngine，直接赋值，不必再转换
        engine.onEnded = { [weak self] in
            Task { @MainActor in self?.next() }
        }        self.engine = engine
        return engine
    }

    private func updateNowPlaying() {
        NowPlayingManager.update(
            book: currentBook,
            chapter: currentChapter,
            elapsed: currentTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }
}
