import SwiftUI

/// 全屏播放页 —— 空壳占位
/// 封面占位、进度条、控制按钮（播放/暂停/上一章/下一章）。
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 48)
                    .overlay(
                        Text("封面占位")
                            .foregroundColor(.secondary)
                    )

                VStack(spacing: 8) {
                    Text(player.currentBook?.title ?? "未播放")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(player.currentChapter?.title ?? "")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // 进度条（占位，未接真实进度）
                Slider(value: $player.progress, in: 0...1)
                    .padding(.horizontal)

                // 控制按钮
                HStack(spacing: 48) {
                    Button {
                        // TODO: 切到上一章
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                    }

                    Button {
                        player.togglePlay()
                    } label: {
                        Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }

                    Button {
                        // TODO: 切到下一章
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                    }
                }
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
    }
}

#Preview {
    PlayerView()
        .environmentObject(PlayerViewModel())
}
