import SwiftUI

/// 书籍卡片 —— 空壳占位
/// 封面用灰色占位块，标题/作者来自 Book 模型。
struct BookCardView: View {
    let book: Book
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay(
                        Text("封面")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    )

                Text(book.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(book.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    BookCardView(book: Book(title: "三体", author: "刘慈欣"), onTap: {})
        .frame(width: 120)
}
