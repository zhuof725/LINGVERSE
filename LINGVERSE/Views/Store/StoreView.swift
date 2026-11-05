import SwiftUI

/// 书城 / 发现页 —— 空壳占位
/// 展示推荐与分类的占位列表。
struct StoreView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("推荐") {
                    ForEach(0..<5, id: \.self) { i in
                        Text("占位推荐位 \(i + 1)")
                            .foregroundColor(.secondary)
                    }
                }
                Section("分类") {
                    ForEach(["科幻", "文学", "历史", "财经", "悬疑"], id: \.self) { c in
                        Text(c)
                    }
                }
            }
            .navigationTitle("书城")
        }
    }
}

#Preview {
    StoreView()
}
