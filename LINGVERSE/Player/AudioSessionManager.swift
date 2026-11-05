import AVFoundation

/// 音频会话。
///
/// 听书场景要的是 `.playback` + `.spokenAudio`：
/// `.playback` 才允许锁屏/后台继续放，`.spokenAudio` 让系统知道这是人声，
/// 来电打断、混合其他音频的行为都会更合理。
enum AudioSessionManager {

    /// 激活会话。每次开始播放前调用 —— 被电话打断后会话会失去 active，需要重新拿。
    @discardableResult
    static func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            // 注册打断通知：来电/闹钟后能自动恢复
            observeInterruptions()
            return true
        } catch {
            Diagnostics.shared.add("audio", "会话激活失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 停止播放时释放，让其他 App 恢复自己的音频。
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 打断

    private static var interruptionObserver: NSObjectProtocol?
    /// 被打断前是否在播，用于恢复。
    nonisolated(unsafe) static var wasPlayingBeforeInterruption = false

    private static func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            switch type {
            case .began:
                // 系统已经把音频停掉了，这里只记录状态，不要再去 setActive(true)
                wasPlayingBeforeInterruption = true
            case .ended:
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                guard options.contains(.shouldResume), wasPlayingBeforeInterruption else { return }
                activate()
                NotificationCenter.default.post(name: .audioShouldResume, object: nil)
            @unknown default:
                break
            }
        }
    }
}

extension Notification.Name {
    /// 打断结束且系统允许恢复时发出，由 ViewModel 接回 play()。
    static let audioShouldResume = Notification.Name("lingverse.audioShouldResume")
}
