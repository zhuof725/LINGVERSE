import Foundation

/// 音频播放引擎协议（空壳阶段：接口就位，实现留待后续）
/// 后续用 AVAudioPlayer 或 AVPlayer 实现该协议即可接入真实播放。
protocol AudioPlaying: AnyObject {
    /// 加载并准备播放一段音频
    func load(url: URL)
    /// 开始/继续播放
    func play()
    /// 暂停播放
    func pause()
    /// 停止并释放资源
    func stop()
    /// 跳转到指定进度（秒）
    func seek(to seconds: TimeInterval)

    /// 当前播放进度（秒）
    var currentTime: TimeInterval { get }
    /// 音频总时长（秒）
    var duration: TimeInterval { get }
    /// 播放状态变化回调（由实现方在状态变化时调用）
    var onStateChange: ((PlaybackState) -> Void)? { get set }
}
