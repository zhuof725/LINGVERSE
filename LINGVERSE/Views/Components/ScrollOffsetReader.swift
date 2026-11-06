import SwiftUI
import UIKit

/// 读 ScrollView 的实时滚动偏移。
///
/// SwiftUI 在 iOS 17 没有 `onScrollGeometryChange`（那是 18 的 API），
/// 而用 GeometryReader + PreferenceKey 读「内容被拉下多少」有几个坑：
///   - 首帧读数不稳定，需要基准校准，稍不注意就会算出一个恒定正值，
///     表现为页面顶部多出一块空白
///   - 探测视图自己是布局的一部分，很容易形成反馈循环
///
/// 直接拿底层 UIScrollView 的 contentOffset 最可靠：它不会撒谎，
/// 也不会因为视图层级变化而漂移。
struct ScrollOffsetReader: UIViewRepresentable {
    /// 滚动时回调，参数是 contentOffset.y（下拉为负，上滚为正）
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        // 延迟到加入视图层级后再找父级 UIScrollView。
        // 只试一次的话，SwiftUI 首次布局时父级链可能还没接好，会找不到；
        // 试几次直到命中为止。
        context.coordinator.scheduleAttach(to: view, attempt: 0)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject {
        var onChange: (CGFloat) -> Void
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        func attach(to view: UIView) {
            guard scrollView == nil else { return }
            var current: UIView? = view
            while let v = current {
                if let sv = v as? UIScrollView {
                    scrollView = sv
                    // contentOffset 是 KVO 友好的，下拉回弹也能拿到实时值
                    observation = sv.observe(\.contentOffset, options: [.new, .initial]) { [weak self] sv, _ in
                        guard let self else { return }
                        // SwiftUI 的 ScrollView 会带 -contentInset.top 的初始偏移，
                        // 把这个补偿掉，让「静止」对应 0。
                        let y = sv.contentOffset.y + sv.adjustedContentInset.top
                        self.onChange(y)
                    }
                    return
                }
                current = v.superview
            }
        }

        /// 最多重试 10 次（约 0.5 秒）。视图层级还没接好时下一轮再找。
        func scheduleAttach(to view: UIView, attempt: Int) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if self.scrollView != nil { return }
                self.attach(to: view)
                if self.scrollView == nil, attempt < 10 {
                    self.scheduleAttach(to: view, attempt: attempt + 1)
                }
            }
        }

        deinit {
            observation?.invalidate()
        }
    }
}
