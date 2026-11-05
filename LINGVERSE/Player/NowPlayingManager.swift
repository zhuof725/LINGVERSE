import Foundation
import MediaPlayer
import UIKit

/// 锁屏 / 控制中心。
///
/// 上一版这里是空实现：`setupRemoteCommands` 注册了回调但都 `return .success` 不做事，
/// 等于把系统的播放按钮吃掉了却什么也不播。现在接真回调。
enum NowPlayingManager {

    /// 封面缓存：锁屏每 0.5 秒刷新一次信息，不能每次都重新下载封面。
    private static var artworkCache: [String: MPMediaItemArtwork] = [:]
    private static var loadingCovers = Set<String>()

    /// 更新「正在播放」信息。`elapsed` 与 `duration` 都是秒。
    static func update(book: LBook?, chapter: LChapter?,
                       elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard let book else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter?.title ?? book.name,
            MPMediaItemPropertyArtist: book.author.isEmpty ? book.sourceName : book.author,
            MPMediaItemPropertyAlbumTitle: book.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }

        if let coverUrl = book.coverUrl, let artwork = artworkCache[coverUrl] {
            info[MPMediaItemPropertyArtwork] = artwork
        } else if let coverUrl = book.coverUrl {
            // 首次：异步取封面，取到后重写一次信息。只触发一次。
            if !loadingCovers.contains(coverUrl) {
                loadingCovers.insert(coverUrl)
                loadArtwork(coverUrl) { artwork in
                    loadingCovers.remove(coverUrl)
                    guard let artwork else { return }
                    artworkCache[coverUrl] = artwork
                    // 期间用户可能切书：只在封面仍属于当前书时补写
                    var merged = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    if merged[MPMediaItemPropertyAlbumTitle] as? String == book.name {
                        merged[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = merged
                    }
                }
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func loadArtwork(_ raw: String, completion: @escaping (MPMediaItemArtwork?) -> Void) {
        guard let url = URL(string: raw) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async { completion(artwork) }
        }.resume()
    }

    /// 注册远程命令。
    static func setupRemoteCommands(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        next: @escaping () -> Void,
        previous: @escaping () -> Void,
        seekToSeconds: @escaping (TimeInterval) -> Void,
        skipBy: @escaping (TimeInterval) -> Void
    ) {
        let center = MPRemoteCommandCenter.shared()

        // 远程命令回调在系统线程上，UI/AVPlayer 操作必须转主线程
        func bind(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> Void) {
            command.removeTarget(nil)
            command.isEnabled = true
            command.addTarget { event in
                DispatchQueue.main.async { handler(event) }
                return .success
            }
        }

        bind(center.playCommand) { _ in play() }
        bind(center.pauseCommand) { _ in pause() }
        bind(center.togglePlayPauseCommand) { _ in toggle() }
        bind(center.nextTrackCommand) { _ in next() }
        bind(center.previousTrackCommand) { _ in previous() }

        // 有声书必须能拖进度：不注册这条，锁屏上没有进度条
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seekToSeconds(event.positionTime)
            return .success
        }

        // 15 秒快进 / 快退，有声音频的标准配置
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.addTarget { _ in
            DispatchQueue.main.async { skipBy(15) }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.addTarget { _ in
            DispatchQueue.main.async { skipBy(-15) }
            return .success
        }
    }
}
