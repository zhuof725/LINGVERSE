import Foundation
import AVFoundation
import Combine

/// `AudioPlaying` 的 AVPlayer 实现。
///
/// 用 AVPlayer 而不是 AVAudioPlayer：有声书多为远程 HTTP 流，
/// AVAudioPlayer 只吃本地文件；AVPlayer 自带缓冲、断网重试、AirPlay。
final class AVPlayerEngine: NSObject, AudioPlaying {
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?

    var onStateChange: ((PlaybackState) -> Void)?
    /// 播放进度回调（秒）。ViewModel 用它刷新 UI 与锁屏信息。
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?

    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var currentTime: TimeInterval {
        let t = player.currentTime()
        return t.isNumeric ? CMTimeGetSeconds(t) : 0
    }

    var duration: TimeInterval {
        guard let item = player.currentItem else { return 0 }
        let d = item.duration
        if d.isNumeric, CMTimeGetSeconds(d) > 0 { return CMTimeGetSeconds(d) }
        // 流媒体在 readyToPlay 之前 duration 是 NaN，先读 seekableRange
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
            return end.isFinite ? end : 0
        }
        return 0
    }

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        installObservers()
    }

    deinit {
        teardown()
    }

    // MARK: - AudioPlaying

    func load(url: URL) {
        teardownItemObservers()

        let asset = AVURLAsset(url: url, options: [
            // 音频流不要等整个文件下完
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            ],
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.onProgress?(self.currentTime, self.duration)
            case .failed:
                Diagnostics.shared.add("player", "加载失败: \(item.error?.localizedDescription ?? "未知")")
                self.state = .idle
            default:
                break
            }
        }
        // 缓冲状态：卡顿时显示 buffering，恢复后回到 playing
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.state == .playing else { return }
            self.state = .buffering
        }

        // 播完自动下一章
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.state = .stopped
            self?.onEnded?()
        }

        player.replaceCurrentItem(with: item)
        state = .idle
    }

    /// 播放到结尾的回调（由 ViewModel 接「自动下一章」）。
    var onEnded: (() -> Void)?

    func play() {
        // 缓冲中重复调用 play 会把状态机搅乱，这里只在真正需要时切
        if state == .playing { return }
        player.play()
        state = .playing
    }

    func pause() {
        guard state == .playing || state == .buffering else { return }
        player.pause()
        state = .paused
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        teardownItemObservers()
        state = .stopped
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // 用零容差，否则 seek 会跳到最近的关键帧，长音频里偏几十秒
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.onProgress?(self.currentTime, self.duration)
        }
    }

    // MARK: - 观察

    private func installObservers() {
        // 每 0.5 秒推一次进度。锁屏信息不需要更密。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.isNumeric ? CMTimeGetSeconds(time) : 0
            self.onProgress?(seconds, self.duration)
        }

        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                if self.state != .playing { self.state = .playing }
            case .waitingToPlayAtSpecifiedRate:
                if self.state != .buffering { self.state = .buffering }
            case .paused:
                if self.state == .playing || self.state == .buffering { self.state = .paused }
            @unknown default:
                break
            }
        }
    }

    private func teardownItemObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        teardownItemObservers()
    }
}

private extension CMTime {
    /// `isNumeric` 之外还要挡住 NaN/无限，否则 UI 上会出现 "nan"。
    var isNumeric: Bool {
        flags.contains(.valid) && !flags.contains(.indefinite)
            && seconds.isFinite
    }
}
