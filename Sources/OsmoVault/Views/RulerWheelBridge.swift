import SwiftUI
import AppKit

/// 让普通鼠标滚轮也能左右平移刻度尺。
///
/// SwiftUI 的横向 `ScrollView` 只认触控板的水平手势；用鼠标滚轮在刻度尺上滚，
/// 事件会直接穿透到外层的纵向列表（列表跟着动，刻度尺纹丝不动）。
/// 这里挂一个本地事件监听：滚轮落在刻度尺范围内时拦下来，直接推底层
/// `NSScrollView` 的内容原点，效果和触控板横扫一致。
///
/// 视图本身零尺寸、不参与命中测试，纯粹用来定位所属的 NSScrollView 并拿到它的窗口坐标
struct RulerWheelBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RulerWheelNSView { RulerWheelNSView() }
    func updateNSView(_ nsView: RulerWheelNSView, context: Context) {}
}

final class RulerWheelNSView: NSView {
    private var monitor: Any?
    private weak var scrollView: NSScrollView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        uninstall()
        guard window != nil else { return }
        install()
    }

    private func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let sv = self.enclosingScrollView() else { return event }
            // 只处理落在刻度尺上的滚轮；其他区域原样放行
            guard event.window == nil || event.window === self.window else { return event }
            let rect = sv.convert(sv.bounds, to: nil)
            guard rect.contains(event.locationInWindow) else { return event }
            // 触控板的横向手势交给系统处理，比自己转更顺滑（还有惯性）
            guard abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY) else { return event }

            // 非精确滚轮（老式鼠标）给的是"行数"，要换算成点，否则一格只挪一点点
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
            // deltaY > 0 表示"往前看"（SDK 已按自然滚动偏好取反过），对应刻度尺往左
            self.scrollBy(x: -event.scrollingDeltaY * scale, in: sv)
            return nil
        }
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 往上找最近的 NSScrollView。SwiftUI 把 ScrollView 内容放在 clip view 的文档视图里
    private func enclosingScrollView() -> NSScrollView? {
        if let sv = scrollView { return sv }
        var cur = superview
        while let v = cur {
            if let sv = v as? NSScrollView {
                scrollView = sv
                return sv
            }
            cur = v.superview
        }
        return nil
    }

    /// 直接推内容原点：`scroll(to:)` 会自动夹在文档范围内，滚到头就停住
    private func scrollBy(x: CGFloat, in sv: NSScrollView) {
        let clip = sv.contentView
        var origin = clip.bounds.origin
        origin.x += x
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
    }

    deinit { uninstall() }
}
