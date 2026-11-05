import Foundation

/// 播放状态（空壳占位）
/// 与播放引擎的 onStateChange 回调对齐，后续由真实引擎驱动。
enum PlaybackState: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case stopped
}
