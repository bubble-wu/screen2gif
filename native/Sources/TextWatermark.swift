import AppKit

/// Render with macOS font fallback so Chinese and color emoji share one text line.
/// The 2x bitmap is reduced to at most 14 px type by the final GIF compositor.
enum TextWatermark {
  static let characterLimit = 40
  static let fontSize: CGFloat = 28

  static func normalized(_ text: String) -> String {
    String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(characterLimit))
  }

  static func bitmap(_ text: String) throws -> NSBitmapImageRep {
    let text = normalized(text)
    guard !text.isEmpty else { throw RenderError.emptyText }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    let padding: CGFloat = 6
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(size.width + padding * 2)),
      pixelsHigh: Int(ceil(size.height + padding * 2)),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RenderError.unavailable }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    // A group alpha also attenuates color emoji, which ignore foregroundColor alpha.
    cg.setAlpha(0.48)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    (text as NSString).draw(at: NSPoint(x: padding, y: padding), withAttributes: attributes)
    cg.endTransparencyLayer()
    context.flushGraphics()
    return bitmap
  }

  static func png(_ text: String) throws -> Data {
    guard let data = try bitmap(text).representation(using: .png, properties: [:]) else {
      throw RenderError.unavailable
    }
    return data
  }

  static func preview(_ text: String) -> NSImage? {
    guard let bitmap = try? bitmap(text) else { return nil }
    let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    image.addRepresentation(bitmap)
    return image
  }

  enum RenderError: LocalizedError {
    case emptyText, unavailable
    var errorDescription: String? {
      switch self {
      case .emptyText: return "水印文字为空。"
      case .unavailable: return "无法绘制文字水印，请重试。"
      }
    }
  }
}
