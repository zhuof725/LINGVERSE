import SwiftUI

/// 迷你播放条。悬浮在 Tab 栏上方，点击展开播放页。
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerViewModel
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: player.currentBook?.coverUrl.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.25))
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentBook?.name ?? "")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(player.currentChapter?.title ?? "未选择章节")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if player.state == .buffering {
                ProgressView().scaleEffect(0.8)
            } else {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button { player.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.footnote)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            // 顶部细进度条：不占空间，一眼能看出播到哪
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: geo.size.width * player.progressRatio, height: 2)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }
}
