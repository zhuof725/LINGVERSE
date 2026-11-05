import SwiftUI

/// 全屏播放页：封面、进度、上一章/播放/下一章。
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var dragRatio: Double?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)

                cover

                VStack(spacing: 6) {
                    Text(player.currentBook?.name ?? "未播放")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(player.currentChapter?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                progressSection

                controls

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 24)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                }
            }
        }
    }

    private var cover: some View {
        AsyncImage(url: player.currentBook?.coverUrl.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.18))
                .overlay(Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.secondary))
        }
        .frame(maxWidth: 280, maxHeight: 280)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private var progressSection: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { dragRatio ?? player.progressRatio },
                    set: { dragRatio = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing()
                        if let value = dragRatio {
                            player.seek(toRatio: value)
                        }
                        dragRatio = nil
                    }
                }
            )
            .disabled(player.duration <= 0)

            HStack {
                Text(timeText(dragRatio.map { $0 * player.duration } ?? player.currentTime))
                Spacer()
                Text(player.duration > 0 ? "-" + timeText(player.duration - (dragRatio.map { $0 * player.duration } ?? player.currentTime)) : "--:--")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button { player.previous() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title2)
            }
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            Button { player.skip(by: 15) } label: {
                Image(systemName: "goforward.15").font(.title2)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
