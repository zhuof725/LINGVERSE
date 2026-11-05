import SwiftUI

/// 迷你播放条 —— 空壳占位
/// 悬浮于 Tab 栏上方，展示当前书/章节与播放切换按钮，点击条身展开全屏播放页。
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerViewModel
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentBook?.title ?? "")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(player.currentChapter?.title ?? "未选择章节")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }
}
