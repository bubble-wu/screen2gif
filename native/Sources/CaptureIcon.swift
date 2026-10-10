import AppKit

/// Small monochrome counterpart of the selected capture-corners app icon.
/// Template rendering lets macOS provide contrast in light/dark menu bars.
enum CaptureIcon {
  private static let idle = make(recording: false)
  private static let active = make(recording: true)

  static func menuBar(recording: Bool) -> NSImage { recording ? active : idle }

  private static func make(recording: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      for (x, y, dx, dy) in [(2.0, 2.0, 1.0, 1.0), (16, 2, -1, 1),
                             (2, 16, 1, -1), (16, 16, -1, -1)] {
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: x, y: y + 4 * dy))
        corner.line(to: NSPoint(x: x, y: y))
        corner.line(to: NSPoint(x: x + 4 * dx, y: y))
        corner.lineWidth = 1.8
        corner.lineCapStyle = .round
        corner.lineJoinStyle = .round
        corner.stroke()
      }
      let dot = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6))
      dot.lineWidth = 1.5
      if recording { dot.fill() } else { dot.stroke() }
      return true
    }
    image.isTemplate = true
    return image
  }
}
