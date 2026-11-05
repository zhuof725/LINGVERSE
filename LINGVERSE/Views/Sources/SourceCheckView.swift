import SwiftUI

/// 书源体检页：一键跑一遍「搜索 → 目录」，看哪些源还活着。
struct SourceCheckView: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = "三体"
    @State private var isRunning = false
    @State private var results: [SourceCheck.Result] = []
    @State private var currentName = ""
    @State private var done = 0

    var body: some View {
        List {
            Section {
                TextField("测试关键字", text: $keyword)
                    .disabled(isRunning)
                Button {
                    run()
                } label: {
                    HStack {
                        if isRunning {
                            ProgressView().scaleEffect(0.8)
                            Text("正在检查 \(currentName)（\(done)/\(store.audioSources.count)）")
                        } else {
                            Label("开始体检", systemImage: "stethoscope")
                        }
                    }
                }
                .disabled(isRunning || store.audioSources.isEmpty)
            } footer: {
                Text("逐条跑「搜索 → 取目录」。串行执行，避免触发书站限流。")
            }

            if !results.isEmpty {
                Section("结果") {
                    ForEach(results) { r in
                        HStack(spacing: 8) {
                            Image(systemName: r.status.symbol)
                                .foregroundStyle(color(for: r.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.sourceName).font(.subheadline)
                                Text(detailText(r))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(r.status.text)
                                .font(.caption2)
                                .foregroundStyle(color(for: r.status))
                        }
                    }
                }
            }
        }
        .navigationTitle("书源体检")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func detailText(_ r: SourceCheck.Result) -> String {
        var parts: [String] = []
        if r.searchCount > 0 { parts.append("搜索 \(r.searchCount) 条") }
        if r.tocCount > 0 { parts.append("目录 \(r.tocCount) 章") }
        if r.searchSeconds > 0 { parts.append(String(format: "%.1fs", r.searchSeconds)) }
        if let failure = r.failure { parts.append(failure) }
        return parts.isEmpty ? "无详情" : parts.joined(separator: " · ")
    }

    private func color(for status: SourceCheck.Result.Status) -> Color {
        switch status {
        case .ok: return .green
        case .noResult: return .orange
        case .tocFailed: return .yellow
        case .failed: return .red
        }
    }

    private func run() {
        let sources = store.audioSources
        guard !sources.isEmpty else { return }
        isRunning = true
        results = []
        done = 0
        currentName = sources[0].bookSourceName

        Task {
            for source in sources {
                await MainActor.run { currentName = source.bookSourceName }
                let r = await SourceCheck.check(source, keyword: keyword)
                await MainActor.run {
                    results.append(r)
                    done += 1
                }
            }
            await MainActor.run { isRunning = false }
        }
    }
}
