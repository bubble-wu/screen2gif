// Interactive verification of the production settings view with isolated state.
// No real defaults, global hotkeys, or system login items are changed.
import AppKit
import ServiceManagement
import SwiftUI

func dbg(_ message: String) { }

private final class PreviewStorage: PreferencesStorage {
  var values: [String: Any] = [:]
  func object(forKey key: String) -> Any? { values[key] }
  func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private final class PreviewLogin: LoginItemService {
  var status: SMAppService.Status = .enabled
  func register() throws { status = .enabled }
  func unregister() throws { status = .notRegistered }
}

@MainActor
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let storage = PreviewStorage()
    let preferences = AppPreferences(storage: storage)
    preferences.watermarkEnabled = true
    preferences.watermarkText = "制作 / 小吴 ✨"
    let service = PreviewLogin()
    let shortcuts = ShortcutStore(storage: storage, registersGlobally: false)
    if CommandLine.arguments.contains("--long") {
      preferences.directory = URL(fileURLWithPath: "/Users/演示/非常长的输出目录/用于验证设置窗口中的路径完整换行与控件布局/项目资料/录制输出")
      preferences.watermarkText = String(repeating: "演示👩🏽‍💻", count: 20)
      shortcuts.setCombo(nil, for: .fullscreen)
      shortcuts.setCombo(KeyCombo(keyCode: 49, modifiers: [.control, .option, .shift, .command], display: "空格"), for: .region)
      service.status = .notFound
    }
    if CommandLine.arguments.contains("--off") {
      preferences.watermarkEnabled = false
      preferences.playSounds = false
      preferences.revealAfterExport = false
      service.status = .notRegistered
    }
    let login = LaunchAtLogin(service: service, storage: storage)
    let content = AppSettingsView(preferences: preferences, launchAtLogin: login, shortcuts: shortcuts,
      onChooseDirectory: {}, onOpenDirectory: {})
    let heightIndex = CommandLine.arguments.firstIndex(of: "--height")
    let height = heightIndex.flatMap { Double(CommandLine.arguments[$0 + 1]) }.map { CGFloat($0) }
    let renderOnly = CommandLine.arguments.contains("--render-only")
    if !renderOnly {
      window = SettingsWindowController.makeWindow(content: content, height: height)
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    print("FONT \(SettingsStyle.nativeFont(13).familyName ?? "missing")")
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
      let path = CommandLine.arguments[index + 1]
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let renderHeight = renderOnly ? height ?? 1280 : 1280
        let view = NSHostingView(rootView: content.frame(width: 660, height: renderHeight))
        view.frame = NSRect(x: 0, y: 0, width: 660, height: renderHeight)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
          view.cacheDisplay(in: view.bounds, to: bitmap)
          try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        if renderOnly { NSApp.terminate(nil) }
      }
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SettingsPreview {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PreviewDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
