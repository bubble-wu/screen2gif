import AppKit
import SwiftUI

// 录制中的可视指示，全屏与框选共用同一套：
//   1. 红框（仅框选）：画在选区之外、对鼠标透明，不入镜、不挡操作。
//   2. 状态条（两种模式）：REC 红点（每秒闪烁）+ 已录时长 + 「停止」按钮。
// 位置规则：
//   框选 → 选区正上方（选区外的画面，天然不入镜）；
//          选区贴着屏幕顶时放进选区顶部内侧，靠采集过滤剔除，不入镜。
//   全屏 → 主屏顶部菜单栏下方，整屏都在录，必须靠采集过滤剔除。
// 状态条可点击但不抢焦点（nonactivating panel + 永不成为 key window），
// 点「停止」不会把被演示的应用晃出去。
// 必须在主线程调用（Model 是 @MainActor）。
enum RecordingOverlay {
    private static var borderWindow: NSWindow?
    private static var barPanel: NSPanel?

    /// 返回所有 overlay 窗口：Recorder 拿去从采集里剔除（excludingWindows）。
    @discardableResult
    static func show(region: CGRect?, onStop: @escaping () -> Void) -> [NSWindow] {
        hide()
        var windows: [NSWindow] = []

        if let region, let screen = NSScreen.screens.first {
            let side: CGFloat = 8
            // region 是 CG 坐标（左上原点），NSWindow 要 AppKit 全局坐标（左下原点）
            let frame = NSRect(
                x: region.minX - side,
                y: screen.frame.maxY - region.maxY - side,
                width: region.width + side * 2,
                height: region.height + side * 2)
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
            borderWindow = w
            windows.append(w)
        }

        // 状态条：先量尺寸再定位
        let startedAt = Date()
        let host = NSHostingView(rootView: StatusBarView(startedAt: startedAt, onStop: onStop))
        let size = host.fittingSize
        host.setFrameSize(size)
        let panel = StatusBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host

        let screenFrame = NSScreen.screens.first?.frame ?? .zero
        let x: CGFloat
        let y: CGFloat  // AppKit 坐标（左下原点）
        if let region {
            // 水平：居中于选区，但不越出屏幕
            let half = size.width / 2
            let centerX = min(max(region.midX, half + 8), screenFrame.maxX - half - 8)
            x = centerX - half
            if region.minY >= size.height + 12 {
                // 选区上方有空间：条底贴选区顶上方 8pt（选区外，不入镜）
                y = screenFrame.maxY - region.minY + 8
            } else {
                // 贴屏幕顶：放进选区顶部内侧 8pt，靠采集过滤不入镜
                y = screenFrame.maxY - region.minY - size.height - 8
            }
        } else {
            // 全屏：主屏顶部、菜单栏下方
            x = screenFrame.midX - size.width / 2
            y = screenFrame.maxY - size.height - 45
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        barPanel = panel
        windows.append(panel)

        return windows
    }

    static func hide() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
        barPanel?.orderOut(nil)
        barPanel = nil
    }
}

/// 红框窗口：透明、不抢事件
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

/// 状态条面板：可点击但不抢焦点
private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class BorderView: NSView {
    private let regionSize: CGSize

    init(regionSize: CGSize) {
        self.regionSize = regionSize
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(width: regionSize.width + 16, height: regionSize.height + 16)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 选区在本视图坐标里的位置：四边各留 8pt
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
    }
}

/// 状态条本体：深色胶囊，红点每秒闪一下，等宽数字计时，右侧停止按钮。
/// TimelineView 每秒重绘驱动计时（顺带驱动红点闪烁），不需要外部 Timer。
private struct StatusBarView: View {
    let startedAt: Date
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt).rounded(.down)))
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(seconds % 2 == 0 ? 1 : 0.35)
                Text("REC \(Self.elapsed(seconds))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize()
                Button(action: onStop) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("停止")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.9)))
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.75)))
        }
    }

    private static func elapsed(_ seconds: Int) -> String {
        // 固定 00:00 宽度，分钟数变化不会撑爆胶囊
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
