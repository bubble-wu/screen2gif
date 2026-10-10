import Combine
import Foundation

protocol PreferencesStorage: AnyObject {
  func object(forKey defaultName: String) -> Any?
  func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: PreferencesStorage {}

enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
  case clear, balanced, compact
  var id: String { rawValue }
  var title: String {
    switch self {
    case .clear: return "清晰优先"
    case .balanced: return "均衡"
    case .compact: return "体积优先"
    }
  }
  var width: Int { switch self { case .clear: return 0; case .balanced: return 1440; case .compact: return 720 } }
  var fps: Int { switch self { case .clear: return 20; case .balanced: return 12; case .compact: return 8 } }
  var frameCap: Int { switch self { case .clear: return 600; case .balanced: return 360; case .compact: return 180 } }
  var detail: String {
    switch self {
    case .clear: return "保留原始像素 · 最多 20 帧/秒\n适合文字、代码和细节演示，文件较大。"
    case .balanced: return "最大宽度 1440 px · 最多 12 帧/秒\n适合日常分享，兼顾清晰度与文件体积。"
    case .compact: return "最大宽度 720 px · 最多 8 帧/秒\n适合短小动图，细小文字会损失清晰度。"
    }
  }
  var cliArguments: [String] {
    ["--width", String(width), "--fps", String(fps), "--max-frames", String(frameCap),
     "--sensitivity", self == .clear ? "high" : "default"]
  }
}

struct ExportSettings: Sendable {
  let directory: URL
  let quality: ExportQuality
  let playSounds: Bool
  let revealAfterExport: Bool
  var watermarkEnabled: Bool = false
  var watermarkText: String = ""

  var effectiveWatermarkText: String? {
    let text = TextWatermark.normalized(watermarkText)
    return watermarkEnabled && !text.isEmpty ? text : nil
  }

  func arguments(input: URL, output: URL, regionPicked: Bool) -> [String] {
    ["convert", input.path, "-o", output.path] + quality.cliArguments
      + (regionPicked ? ["--crop", "off"] : [])
  }
}

@MainActor
final class AppPreferences: ObservableObject {
  static let shared = AppPreferences()
  static let outputDirKey = "outputDirectory" // Preserve existing users' selection.
  static var defaultDirectory: URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
  }
  private let storage: PreferencesStorage

  @Published var directory: URL {
    didSet { storage.set(directory.path, forKey: Self.outputDirKey) }
  }
  @Published var quality: ExportQuality {
    didSet { storage.set(quality.rawValue, forKey: "exportQuality") }
  }
  @Published var playSounds: Bool {
    didSet { storage.set(playSounds, forKey: "playSounds") }
  }
  @Published var revealAfterExport: Bool {
    didSet { storage.set(revealAfterExport, forKey: "revealAfterExport") }
  }
  @Published var watermarkEnabled: Bool {
    didSet { storage.set(watermarkEnabled, forKey: "watermarkEnabled") }
  }
  @Published var watermarkText: String {
    didSet {
      if watermarkText.count > TextWatermark.characterLimit {
        watermarkText = String(watermarkText.prefix(TextWatermark.characterLimit))
      }
      storage.set(watermarkText, forKey: "watermarkText")
    }
  }

  init(storage: PreferencesStorage = UserDefaults.standard) {
    self.storage = storage
    if let path = storage.object(forKey: Self.outputDirKey) as? String, !path.isEmpty {
      directory = URL(fileURLWithPath: path)
    } else { directory = Self.defaultDirectory }
    quality = (storage.object(forKey: "exportQuality") as? String).flatMap(ExportQuality.init(rawValue:)) ?? .balanced
    playSounds = storage.object(forKey: "playSounds") as? Bool ?? true
    revealAfterExport = storage.object(forKey: "revealAfterExport") as? Bool ?? true
    watermarkEnabled = storage.object(forKey: "watermarkEnabled") as? Bool ?? false
    watermarkText = String((storage.object(forKey: "watermarkText") as? String ?? "")
      .prefix(TextWatermark.characterLimit))
  }

  func resetAll() {
    directory = Self.defaultDirectory
    quality = .balanced
    playSounds = true
    revealAfterExport = true
    watermarkEnabled = false
    watermarkText = ""
  }

  var snapshot: ExportSettings {
    ExportSettings(directory: directory, quality: quality, playSounds: playSounds,
                   revealAfterExport: revealAfterExport, watermarkEnabled: watermarkEnabled,
                   watermarkText: watermarkText)
  }
}
