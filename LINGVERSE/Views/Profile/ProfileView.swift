import SwiftUI

/// 我的 / 设置页 —— 空壳占位
/// 展示未登录、下载管理、设置的占位列表。
struct ProfileView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("未登录")
                                .font(.headline)
                            Text("点击登录（占位）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("下载管理") {
                    Text("暂无下载（占位）")
                        .foregroundColor(.secondary)
                }

                Section("设置") {
                    Text("播放设置（占位）")
                    Text("关于")
                }
            }
            .navigationTitle("我的")
        }
    }
}

#Preview {
    ProfileView()
}
