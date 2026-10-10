import AppKit

// 全屏透明 overlay：拖拽框选录制区域，返回 CG 坐标（点，左上原点）。
// Esc 或单击不拖拽 = 取消（返回 nil）。
enum RegionPicker {
  private static var activeWindow: NSWindow?
  static func pick(completion: @escaping (CGRect?) -> Void) {
    DispatchQueue.main.async {
      guard let screen = NSScreen.screens.first else {
        completion(nil)
        return
      }
      let window = makeWindow(frame: screen.frame, completion: completion)
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(window.contentView)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  /// Kept separate from showing the window so its ownership can be tested.
  static func makeWindow(frame: CGRect, completion: @escaping (CGRect?) -> Void) -> NSWindow {
    let window = OverlayWindow(
      contentRect: frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let view = SelectionView(frame: NSRect(origin: .zero, size: frame.size))
    view.onPick = { [weak window, weak view] rect in
      guard view?.onPick != nil else { return }
      view?.onPick = nil
      window?.orderOut(nil)
      window?.contentView = nil
      activeWindow = nil
      completion(rect)
    }
    activeWindow = window
    window.isReleasedWhenClosed = false
    window.contentView = view
    return window
  }

}

// borderless 窗口默认 canBecomeKey == false，收不到键盘事件，Esc 就是死的。
private final class OverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
  var onPick: ((CGRect?) -> Void)?
  private var anchor: CGPoint?
  private var rect: CGRect = .zero

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    window?.makeFirstResponder(self)
  }

  // AppKit 窗口坐标（左下原点）→ CG 坐标（左上原点）
  private func cgPoint(_ event: NSEvent) -> CGPoint {
    let p = convert(event.locationInWindow, to: nil)
    let h = window?.screen?.frame.height ?? 0
    let w = window?.screen?.frame.width ?? 0
    return CGPoint(x: min(max(0, p.x), w), y: min(max(0, h - p.y), h))
  }

  override func mouseDown(with event: NSEvent) {
    anchor = cgPoint(event)
    rect = .zero
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor else { return }
    let p = cgPoint(event)
    rect = CGRect(
      x: min(anchor.x, p.x), y: min(anchor.y, p.y),
      width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let picked = (rect.width >= 16 && rect.height >= 16) ? rect : nil
    onPick?(picked)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { onPick?(nil) }   // Esc
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.fill(bounds)

    guard rect.width > 0 else {
      let hint = "拖拽框选录制区域 · Esc 取消" as NSString
      let style = NSMutableParagraphStyle()
      style.alignment = .center
      hint.draw(
        in: CGRect(x: 0, y: bounds.midY - 14, width: bounds.width, height: 28),
        withAttributes: [
          .foregroundColor: NSColor.white,
          .font: NSFont.systemFont(ofSize: 20, weight: .medium),
          .paragraphStyle: style,
        ])
      return
    }

    // rect 是 CG 坐标，绘制要换回窗口坐标（左下原点）
    let h = window?.screen?.frame.height ?? 0
    let view = CGRect(
      x: rect.minX, y: h - rect.maxY,
      width: rect.width, height: rect.height)

    ctx.clear(view)
    ctx.setStrokeColor(NSColor.systemBlue.cgColor)
    ctx.setLineWidth(2)
    ctx.setLineDash(phase: 0, lengths: [6, 4])
    ctx.stroke(view)

    let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
    label.draw(
      at: CGPoint(x: view.minX + 6, y: view.minY + 6),
      withAttributes: [
        .foregroundColor: NSColor.white,
        .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular),
      ])
  }
}
