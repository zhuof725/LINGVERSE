import SwiftUI

/// 书架卡片。
struct BookCardView: View {
    let book: LBook
    var isPlaying: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: book.coverUrl.flatMap(URL.init(string:))) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.18))
                            .overlay(
                                Image(systemName: "book.closed")
                                    .foregroundStyle(.secondary)
                            )
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }

                Text(book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(book.author.isEmpty ? book.sourceName : book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                LibraryStore.shared.remove(book)
            } label: {
                Label("从书架移除", systemImage: "trash")
            }
        }
    }
}
