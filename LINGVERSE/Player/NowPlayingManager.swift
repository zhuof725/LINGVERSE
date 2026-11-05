import MediaPlayer

/// 锁屏 / 控制中心信息管理（空壳：接口就位，播放时填充）
/// 预留：配合 MPNowPlayingInfoCenter 与 MPRemoteCommandCenter 实现锁屏/耳机线控。
enum NowPlayingManager {
    /// 更新锁屏/控制中心的「正在播放」信息。
    static func update(
        book: Book?,
        chapter: Chapter?,
        progress: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        guard let chapter else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyArtist: book?.author ?? "",
            MPMediaItemPropertyAlbumTitle: book?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        // 封面：空壳阶段跳过 MPMediaItemArtwork，接入真实封面资源后补充。

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 注册锁屏/控制中心的远程命令（播放/暂停/上一章/下一章）。
    /// 注意：Target 返回 .success 表示已处理；空壳阶段回调留空，后续接 PlayerViewModel。
    static func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            // TODO: 转发到 PlayerViewModel.togglePlay() 等
            return .success
        }
        center.pauseCommand.addTarget { _ in
            // TODO: 转发到 PlayerViewModel
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            // TODO: 转发到 PlayerViewModel
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            // TODO: 切到下一章
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            // TODO: 切到上一章
            return .success
        }
    }
}
