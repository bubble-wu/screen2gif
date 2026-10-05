import AppKit

// 录制中的可视指示：选区外一圈红框 + 选区上方 REC 标签。
// 边框和标签都画在录制区域之外、窗口对鼠标完全透明，
// 所以既不挡被录的操作，也不会被录进成片。
// 必须在主线程调用（Model 是 @MainActor）。
enum RecordingOverlay {
    private static var window: NSWindow?

    static func show(region: CGRect?) {
        hide()
        // 全屏录制不加框（整屏都是录制区，画哪都会入镜），靠提示音 + 菜单栏图标
        guard let region, let screen = NSScreen.screens.first else { return }
        let side: CGFloat = 8   // 选区四周余量
        let top: CGFloat = 30   // 顶部 REC 标签区
        // region 是 CG 坐标（左上原点），NSWindow 要 AppKit 全局坐标（左下原点）
        let frame = NSRect(
            x: region.minX - side,
            y: screen.frame.maxY - region.maxY - side,
            width: region.width + side * 2,
            height: region.height + side * 2 + top)
        let w = OverlayWindow(
            contentRect: frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = BorderView(regionSize: region.size)
        w.orderFrontRegardless()
        window = w
    }

    static func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

private final class BorderView: NSView {
    private let regionSize: CGSize

    init(regionSize: CGSize) {
        self.regionSize = regionSize
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(width: regionSize.width + 16, height: regionSize.height + 46)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 选区在本视图坐标里的位置：底部和左右各留 8pt，顶部额外 38pt 给标签
    private var regionRect: NSRect {
        NSRect(x: 8, y: 8, width: regionSize.width, height: regionSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // path 从选区外扩 4pt、线宽 4pt → 红色实心带落在选区外 2..6pt，不会入镜
        let border = CGPath(
            roundedRect: regionRect.insetBy(dx: -4, dy: -4),
            cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(border)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(4)
        ctx.strokePath()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .shadow: shadow,
        ]
        let label = "●  REC" as NSString
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: CGPoint(x: regionRect.midX - size.width / 2, y: regionRect.maxY + 12),
            withAttributes: attrs)
    }
}
