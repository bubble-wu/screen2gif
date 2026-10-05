import AppKit
import ScreenCaptureKit
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
    /// onFocused：框选对焦动画完成（画面清晰 = 录制开始）时回调，用于播放提示音。
    @discardableResult
    static func show(region: CGRect?, onStop: @escaping () -> Void, onFocused: @escaping () -> Void) -> [NSWindow] {
        hide()
        var windows: [NSWindow] = []

        if let region, let screen = NSScreen.screens.first {
            // 28pt 余量：除了角标本身，还要容纳对焦动画的外扩起点（22pt）
            let side: CGFloat = 28
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
            let borderView = BorderView(regionSize: region.size)
            w.contentView = borderView
            w.orderFrontRegardless()
            borderWindow = w
            windows.append(w)

            // 对焦开场 = 选区内容虚化→清晰 + 角标收拢，两者要同步开始，
            // 所以等快照抓好了才 beginFocus（此刻 overlay 已上屏，
            // 抓图时把自己排除，避免把角标冻进快照）
            Task { @MainActor in
                let snap = await Self.captureRegion(region, excluding: w)
                borderView.beginFocus(snapshot: snap, onFocused: onFocused)
            }
            // 抓图卡死时的兜底：到点强制开场（只有角标收拢，无虚化）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                borderView.beginFocus(snapshot: nil, onFocused: onFocused)
            }
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

    /// 抓取选区当前画面（CG 坐标，主屏）。失败返回 nil，调用方跳过虚化开场。
    /// CGWindowListCreateImage / CGDisplayCreateImage 在 macOS 26 SDK 均
    /// unavailable，只能走 SCScreenshotManager（异步）。
    @MainActor
    private static func captureRegion(_ region: CGRect, excluding excluded: NSWindow) async -> CGImage? {
        guard let screen = NSScreen.screens.first else { return nil }
        let rect = region.intersection(CGRect(origin: .zero, size: screen.frame.size))
        guard !rect.isNull, rect.width > 8, rect.height > 8 else { return nil }
        do {
            let content = try await SCShareableContent.current
            let display = content.displays.first { $0.frame.origin == .zero }
                ?? content.displays.first
            guard let display else { return nil }
            // overlay 已上屏，不把自己排除就会把角标冻进快照
            let excludedSC = content.windows.filter { $0.windowID == excluded.windowNumber }
            let filter = SCContentFilter(display: display, excludingWindows: excludedSC)

            // 这里的 captureImage 收 SCStreamConfiguration（与 Recorder 同一套数学）：
            // sourceRect 是所选显示器自己的逻辑坐标系，width/height 是输出像素
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(
                x: rect.minX - display.frame.minX,
                y: rect.minY - display.frame.minY,
                width: rect.width, height: rect.height)
            let scale: CGFloat
            if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                scale = CGFloat(mode.pixelWidth) / display.frame.width
            } else {
                scale = CGFloat(display.width) / display.frame.width
            }
            config.width = Int((rect.width * scale).rounded())
            config.height = Int((rect.height * scale).rounded())
            config.capturesAudio = false
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            dbg("focus snapshot failed: \(error.localizedDescription)")
            return nil
        }
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

    private var began = false

    init(regionSize: CGSize) {
        self.regionSize = regionSize
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(width: regionSize.width + 56, height: regionSize.height + 56)))
    }

    /// 对焦开场：虚化层 + 角标收拢同步启动（等快照就绪才调用，保证音画对齐）。
    /// 幂等：快照任务与兜底定时器谁先到谁生效。
    func beginFocus(snapshot: CGImage?, onFocused: @escaping () -> Void) {
        guard !began else { return }
        began = true
        if let snapshot {
            let focus = FocusBlurView(snapshot: snapshot)
            focus.frame = regionRect
            addSubview(focus)
            focus.start()
        }
        setupCorners()
        // 对焦完成（≈0.44s：虚化拉清 0.42 + 闪烁）：提示音时机交给调用方
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) { onFocused() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 选区在本视图坐标里的位置：四边各留 28pt（对焦动画外扩也在窗内）
    private var regionRect: NSRect {
        NSRect(x: 28, y: 28, width: regionSize.width, height: regionSize.height)
    }

    /// 四个细角标（取景框风）。每个角是一个子 NSView，纯 AppKit 坐标，
    /// 动画走 animator()（frame + alpha），不碰 CoreAnimation 的 layer 坐标歧义。
    private func setupCorners() {
        let gap: CGFloat = 4     // 角标与选区边缘间距
        let arm: CGFloat = 15    // L 形臂长
        let r = regionRect
        let center = CGPoint(x: r.midX, y: r.midY)

        // (拐点, 拐点在包围盒中的角)：拐点 = 选区角向外偏 gap
        // 包围盒 = 拐点出发、沿两条臂方向的 arm×arm 方框
        let specs: [(NSPoint, CornerMarkView.Corner)] = [
            (NSPoint(x: r.minX - gap, y: r.minY - gap), .bottomLeft),
            (NSPoint(x: r.maxX + gap, y: r.minY - gap), .bottomRight),
            (NSPoint(x: r.minX - gap, y: r.maxY + gap), .topLeft),
            (NSPoint(x: r.maxX + gap, y: r.maxY + gap), .topRight),
        ]

        for (pivot, corner) in specs {
            let view = CornerMarkView(corner: corner, arm: arm)
            let finalOrigin: NSPoint
            switch corner {
            case .bottomLeft: finalOrigin = pivot
            case .bottomRight: finalOrigin = NSPoint(x: pivot.x - arm, y: pivot.y)
            case .topLeft: finalOrigin = NSPoint(x: pivot.x, y: pivot.y - arm)
            case .topRight: finalOrigin = NSPoint(x: pivot.x - arm, y: pivot.y - arm)
            }
            view.frame = NSRect(origin: finalOrigin, size: CGSize(width: arm, height: arm))
            addSubview(view)

            // 对焦动画：从拐点向外 22pt 的方向收拢到位（0.42s ease-out）。
            // 方向 = 拐点相对选区中心的象限。
            let dir = NSPoint(
                x: pivot.x < center.x ? -22 : 22,
                y: pivot.y < center.y ? -22 : 22)
            view.setFrameOrigin(NSPoint(x: finalOrigin.x + dir.x, y: finalOrigin.y + dir.y))
            view.alphaValue = 0

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.42
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
                view.animator().setFrameOrigin(finalOrigin)
            })

            // 到位后闪一下（对焦清晰 = 录制开始）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
                view.alphaValue = 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    view.alphaValue = 1
                }
            }
        }
    }
}

/// 单个 L 形角标：深灰主线 + 白色 halo，深浅背景上都清晰。
private final class CornerMarkView: NSView {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private let corner: Corner
    private let arm: CGFloat

    init(corner: Corner, arm: CGFloat) {
        self.corner = corner
        self.arm = arm
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // L 的两个端点：拐点 + 沿两臂方向（bounds y 向上）
        let (pivot, e1, e2): (NSPoint, NSPoint, NSPoint)
        switch corner {
        case .bottomLeft:
            pivot = .zero
            e1 = NSPoint(x: arm, y: 0); e2 = NSPoint(x: 0, y: arm)
        case .bottomRight:
            pivot = NSPoint(x: arm, y: 0)
            e1 = .zero; e2 = NSPoint(x: arm, y: arm)
        case .topLeft:
            pivot = NSPoint(x: 0, y: arm)
            e1 = NSPoint(x: arm, y: arm); e2 = .zero
        case .topRight:
            pivot = NSPoint(x: arm, y: arm)
            e1 = NSPoint(x: 0, y: arm); e2 = NSPoint(x: arm, y: 0)
        }

        let path = NSBezierPath()
        path.move(to: pivot); path.line(to: e1)
        path.move(to: pivot); path.line(to: e2)
        path.lineCapStyle = .round

        // 白色 halo 先画（粗），深灰主线后画（细）——任何背景都可见
        path.lineWidth = 4.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.lineWidth = 2
        NSColor(calibratedWhite: 0.24, alpha: 1).setStroke()
        path.stroke()
    }
}

/// 对焦开场：选区内容先虚化再拉清晰（相机对焦语义）。
/// 快照来自 overlay 上屏前的屏幕抓图；高斯模糊半径随时间收敛到 0，
/// 结束后移除视图、露出真实内容。本窗口已被采集过滤剔除，
/// 这段动画只给用户看，不会录进成片。
private final class FocusBlurView: NSView {
    private let snapshot: CGImage
    private let ciImage: CIImage
    private let ciContext = CIContext()
    private var timer: Timer?
    private let duration: TimeInterval = 0.42
    private let maxSigma: Double = 14
    private let startTime = CACurrentMediaTime()

    init(snapshot: CGImage) {
        self.snapshot = snapshot
        self.ciImage = CIImage(cgImage: snapshot)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = snapshot
        layer?.contentsGravity = .resize
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
    }

    func start() {
        // 轻微缩放呼吸（1.03 → 1）增强镜头感；只动 presentation，不动模型
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.03
        scale.toValue = 1.0
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(scale, forKey: "focusScale")

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.tick()
        }
    }

    private func tick() {
        // 窗口已被收起（极短的录制）就直接收工
        guard window != nil else { finish(); return }
        let p = min(1.0, (CACurrentMediaTime() - startTime) / duration)
        if p >= 1.0 {
            finish()
            return
        }
        // easeOutCubic：锐度快速跟上，虚化尾巴缓收
        let sigma = maxSigma * pow(1 - p, 3)
        renderAsync(sigma: sigma)
    }

    private func renderAsync(sigma: Double) {
        let image = ciImage
        let context = ciContext
        let extent = ciImage.extent
        let sharp = snapshot
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let output: CGImage
            if sigma < 0.4 {
                output = sharp
            } else {
                // AffineClamp 把四周无限延伸，blur 才不会把边缘虚成透明
                let clamp = CIFilter(name: "CIAffineClamp")!
                clamp.setValue(image, forKey: kCIInputImageKey)
                let blur = CIFilter(name: "CIGaussianBlur")!
                blur.setValue(clamp.outputImage, forKey: kCIInputImageKey)
                blur.setValue(sigma, forKey: "inputRadius")
                output = context.createCGImage(
                    blur.outputImage!.cropped(to: extent), from: extent)!
            }
            DispatchQueue.main.async { self?.layer?.contents = output }
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        removeFromSuperview()
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
