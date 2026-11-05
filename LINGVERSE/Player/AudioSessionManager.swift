import AVFoundation

/// 音频会话管理器（空壳：已配置后台播放所需的会话类别）
/// 预留：后续在真正开始播放前调用 activate()。
enum AudioSessionManager {
    /// 激活音频会话，配置为「后台播放 + 语音内容」。
    /// 听书场景常用：.playback 允许后台播放，.spokenAudio 优化语音输出。
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            // 空壳阶段仅打印，不处理
            print("[AudioSession] activate failed: \(error)")
        }
    }

    /// 停止播放时释放音频会话，并通知其他 App 恢复各自音频。
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
