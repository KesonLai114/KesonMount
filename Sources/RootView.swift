import AppKit

/// 包装 WKWebView 的根视图。
///
/// App 用了透明标题栏 + `.fullSizeContentView`，WKWebView 会铺满整个窗口、
/// 连标题栏区域也盖住，于是系统原本的「拖标题栏移动窗口」失效。
/// 这里在顶部标题栏这一条带上拦截鼠标事件，把拖动交回给系统的
/// `performWindowDrag`——它走的是窗口表面快速移动路径，
/// 不会触发 WebView 重排，所以拖动是跟手的、不卡的。
/// 其余区域一律放给 WebView，按钮点击、页面滚动都不受影响。
final class RootView: NSView {

    /// 顶部可拖动区域高度，大致对齐 HTML 里 <header> 的实际高度
    private let dragBandHeight: CGFloat = 96
    /// 左上角红黄绿交通灯，留点余量不拦截
    private let ignoreLeft: CGFloat = 84
    /// 右半部分留给「扫描/刷新/添加」按钮，不拦截
    private let rightLimitRatio: CGFloat = 0.55

    /// 上一次拖动的位置，用来判断这次算不算「拖」
    private var lastDragPoint: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let h = bounds.height
        let inBand = point.y > h - dragBandHeight
        let notInTrafficLights = point.x > ignoreLeft
        let beforeButtons = point.x < bounds.width * rightLimitRatio
        if inBand && notInTrafficLights && beforeButtons {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        lastDragPoint = event.locationInWindow

        // 立刻开始系统原生拖动：这一步之后鼠标移动由 AppKit 内部接管，
        // 窗口整体平移、不重排内容，所以手感跟系统标题栏一样顺。
        window.performDrag(with: event)

        // 走到这里说明用户只是点了一下（没拖动）
        lastDragPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        // 正常拖动时根本进不到这里（系统拖动循环已接管）；
        // 只有极少数情况（例如拖动被中断）才会走到，做一次兜底移动。
        guard let window, let last = lastDragPoint else { return }
        let cur = event.locationInWindow
        let dx = cur.x - last.x
        let dy = cur.y - last.y
        if dx != 0 || dy != 0 {
            var f = window.frame
            f.origin.x += dx
            f.origin.y += dy
            window.setFrameOrigin(f.origin)
            lastDragPoint = cur
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }
}
