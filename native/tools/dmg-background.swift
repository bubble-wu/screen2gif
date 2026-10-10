import AppKit

// Finder uses point coordinates; the 2x image stays sharp on Retina displays.
@main
struct DMGBackground {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      throw NSError(domain: "screen2gif", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Usage: dmg-background <output.png> <version>"])
    }
    let width = 640, height = 420, scale = 2
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: NSColor(calibratedWhite: 0.985, alpha: 1),
               ending: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1))!
      .draw(in: canvas, angle: -90)

    func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
              size: CGFloat, weight: NSFont.Weight = .regular,
              color: NSColor = .secondaryLabelColor, centered: Bool = false) {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = centered ? .center : .left
      (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 42), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph,
      ])
    }
    text("screen2gif", x: 40, y: 332, width: 440, size: 30, weight: .semibold, color: .labelColor)
    text("屏幕操作，变成小而清晰的 GIF", x: 42, y: 301, width: 500, size: 14)
    text("v\(CommandLine.arguments[2])", x: 498, y: 335, width: 102, size: 13, centered: true)

    // App and Applications icons are placed by Finder at (180, 205)/(460, 205).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 282, y: 215))
    arrow.line(to: NSPoint(x: 354, y: 215))
    arrow.move(to: NSPoint(x: 340, y: 227))
    arrow.line(to: NSPoint(x: 354, y: 215))
    arrow.line(to: NSPoint(x: 340, y: 203))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.56, alpha: 1).setStroke()
    arrow.stroke()

    text("拖入 Applications 完成安装", x: 60, y: 92, width: 520,
         size: 18, weight: .medium, color: .labelColor, centered: true)
    text("复制完成后推出磁盘，再从「应用程序」打开", x: 40, y: 61,
         width: 560, size: 13, centered: true)
    NSGraphicsContext.restoreGraphicsState()
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
  }
}
