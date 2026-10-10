import AppKit
import CoreText
import SwiftUI

/// Tokens from design/settings.pen, node AAfT7. Resources are registered per process.
enum SettingsStyle {
  static let background = Color(hex: 0xFAFAFA)
  static let panel = Color(hex: 0xF0F0F2)
  static let text = Color(hex: 0x232428)
  static let secondary = Color(hex: 0x71747A)
  static let accent = Color(hex: 0x007AFF)
  static let border = Color(hex: 0xD9DADF)
  static let cardBorder = Color(hex: 0xE7E8EC)
  static let separator = Color(hex: 0xEFF0F3)
  static let detail = Color(hex: 0x5F6268)
  static let keycap = Color(hex: 0xF3F4F6)
  static let keycapBorder = Color(hex: 0xE3E4E8)
  static let width: CGFloat = 660
  static let sectionGap: CGFloat = 18

  static var resourceURL: URL {
    Bundle.main.resourceURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  }

  private static let fontDescriptor: CTFontDescriptor = {
    let url = resourceURL.appendingPathComponent("Fonts/NotoSansSC.ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
       let descriptor = descriptors.first { return descriptor }
    assertionFailure("Missing bundled Noto Sans SC font")
    return CTFontDescriptorCreateWithNameAndSize("Noto Sans SC" as CFString, 13)
  }()

  static func nativeFont(_ size: CGFloat, weight: Int = 400) -> NSFont {
    // OpenType 'wght' axis; do not rely on the variable font's default (Thin).
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(fontDescriptor,
      [kCTFontVariationAttribute: [0x77676874: weight]] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
  }

  static func font(_ size: CGFloat, weight: Int = 400) -> Font {
    Font(nativeFont(size, weight: weight))
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
  }
}

struct SettingsIcon: View {
  let name: String
  var size: CGFloat = 15
  var color: Color = SettingsStyle.text

  var body: some View {
    if let image = NSImage(contentsOf: SettingsStyle.resourceURL
      .appendingPathComponent("Lucide/\(name).pdf")) {
      Image(nsImage: image).resizable().renderingMode(.template)
        .foregroundStyle(color).frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
}

struct SettingsCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(spacing: 0) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsStyle.cardBorder, lineWidth: 1))
  }
}

struct SettingsDivider: View {
  var body: some View { SettingsStyle.separator.frame(height: 1).accessibilityHidden(true) }
}

struct SettingsDetail: View {
  let text: String
  var body: some View {
    Text(text).font(SettingsStyle.font(11)).foregroundStyle(SettingsStyle.detail)
      .lineSpacing(1).fixedSize(horizontal: false, vertical: true)
  }
}

struct SettingsRow<Control: View>: View {
  let title: String
  var detail: String? = nil
  @ViewBuilder var control: Control

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(SettingsStyle.font(13))
          .fixedSize(horizontal: false, vertical: true)
        if let detail { SettingsDetail(text: detail) }
      }.frame(maxWidth: .infinity, alignment: .leading)
      control
    }.padding(.vertical, 11).padding(.horizontal, 14)
  }
}

struct SettingsButtonStyle: ButtonStyle {
  var capsule = false
  var cornerRadius: CGFloat = 7
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.65 : 1)
      .background(capsule ? Color(hex: 0xEAF2FF) : .white,
        in: RoundedRectangle(cornerRadius: capsule ? 20 : cornerRadius))
      .overlay(RoundedRectangle(cornerRadius: capsule ? 20 : cornerRadius)
        .strokeBorder(capsule ? .clear : SettingsStyle.border, lineWidth: 1))
      .contentShape(Rectangle())
  }
}

struct SettingsSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      Capsule().fill(configuration.isOn ? SettingsStyle.accent : SettingsStyle.border)
        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
          Circle().fill(.white).frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(2)
        }.frame(width: 34, height: 20)
    }
    .buttonStyle(.plain)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
    }
  }
}
