import SwiftUI

/// 书库（书架）页 —— 空壳占位
/// 展示占位书籍网格，点击即载入播放（仅更新全局状态）。
struct LibraryView: View {
    @EnvironmentObject private var player: PlayerViewModel

    // 占位数据（空壳阶段用，后续替换为真实数据源）
    private let sampleBooks: [Book] = [
        Book(title: "三体", author: "刘慈欣", category: "科幻"),
        Book(title: "活着", author: "余华", category: "文学"),
        Book(title: "明朝那些事儿", author: "当年明月", category: "历史")
    ]

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(sampleBooks) { book in
                        BookCardView(book: book) {
                            player.load(book: book)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("书库")
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(PlayerViewModel())
}
