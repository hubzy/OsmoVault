import SwiftUI
import AppKit

/// 让普通鼠标滚轮也能左右平移刻度尺。
///
/// SwiftUI 的横向 `ScrollView` 只认触控板的水平手势；用鼠标滚轮在刻度尺上滚，
/// 事件会直接穿透到外层的纵向列表（列表跟着动，刻度尺纹丝不动）。
///
/// 早先的做法是挂监听后直接推底层 `NSScrollView` 的 content origin，问题在于
/// **两套滚动状态在抢同一份数据**：`scrollTo(anchor: .center)` 越界时不夹取，
/// 内容会被推到边界之外（刻度尺左边钻到导航栏底下），再往回滚又被这里的夹取挡住，
/// 就成了"滚不回来、也滚不完"。
/// 现在刻度尺不再用 `NSScrollView`（见 `RulerStrip`）：位置完全由 SwiftUI 的
/// offset 控制，只在 `clamped()` 一处夹取。这里只负责把滚轮事件翻译成横向位移，
/// 不再碰任何滚动状态。
struct RulerWheelRelay: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> RulerWheelRelayView {
        let view = RulerWheelRelayView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: RulerWheelRelayView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class RulerWheelRelayView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    /// 完全不参与命中测试：点击、双击要落到下面真正的月份按钮上
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        uninstall()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let handler = self.onScroll else { return event }
            guard let window = self.window, event.window === window else { return event }
            // 只吃落在刻度尺上的滚轮，其他区域原样放行（列表照常上下滚）
            guard self.convert(self.bounds, to: nil).contains(event.locationInWindow) else { return event }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // 触控板横滑给 dx，鼠标滚轮给 dy，谁大听谁的
            let raw = abs(dx) >= abs(dy) ? dx : dy
            guard raw != 0 else { return event }
            // 非精确滚轮（老式鼠标）给的是"行数"，换算成点，否则一格只挪一点点
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
            // 两个方向都是"正数 = 往回想看"，统一取反成 offset 增量
            handler(-raw * scale)
            return nil
        }
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { uninstall() }

    /// 透明、不吃事件，只是用来圈出"哪块区域属于刻度尺"
    override var isOpaque: Bool { false }
}
