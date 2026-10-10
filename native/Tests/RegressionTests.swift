import AppKit
import Foundation
import ServiceManagement

func dbg(_ message: String) { }

@MainActor
private final class MockLoginItem: LoginItemService {
  var status: SMAppService.Status = .notRegistered
  var registeredStatus: SMAppService.Status = .enabled
  var registrationCount = 0
  var unregistrationCount = 0
  var failure: Error?
  func register() throws {
    registrationCount += 1
    if let failure { throw failure }
    status = registeredStatus
  }
  func unregister() throws {
    unregistrationCount += 1
    if let failure { throw failure }
    status = .notRegistered
  }
}

private final class MemoryPreferences: PreferencesStorage {
  var values: [String: Any] = [:]
  func object(forKey key: String) -> Any? { values[key] }
  func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
struct RegressionTests {
  @MainActor static func main() async throws {
    var passed = 0
    func check(_ label: String, _ body: () throws -> Void) rethrows {
      try body()
      passed += 1
      print("PASS \(label)")
    }
    func expect(_ value: @autoclosure () -> Bool, _ label: String = "assertion") {
      if !value() { fatalError(label) }
    }

    check("old session completion cannot finish its replacement") {
      var state = RecordingLifecycle()
      let old = state.begin()
      expect(state.started(old))
      expect(state.finish(old))
      let current = state.begin()
      expect(!state.started(old))
      expect(!state.finish(old))
      expect(state.accepts(current))
      expect(!state.isRecording)
      expect(state.started(current))
      expect(state.isRecording)
      expect(state.finish(current))
      expect(!state.isRecording && state.id == nil)
      expect(!state.finish(current))
    }

    check("starting is not recording; cancellation invalidates readiness") {
      var state = RecordingLifecycle()
      let id = state.begin()
      expect(!state.isRecording)
      state.finish(id)
      expect(!state.started(id))
    }

    let ready = CaptureResult<Int>()
    ready.resolve(.success(42))
    ready.resolve(.success(99))
    let earlyValue = try await ready.value()
    check("delegate readiness arriving before wait is retained once") { expect(earlyValue == 42) }

    let late = CaptureResult<Int>()
    let began = Date()
    do {
      _ = try await captureWithDeadline(seconds: 0.04) { try await late.value() }
      fatalError("missing timeout")
    } catch CaptureDeadlineError.timeout { }
    check("unresponsive operation returns at deadline") { expect(Date().timeIntervalSince(began) < 1) }
    late.resolve(.success(1)) // A late callback must not resume a continuation twice.

    let blocked = CaptureResult<Int>()
    let pending = Task { @MainActor in
      try await captureWithDeadline(seconds: 60) { try await blocked.value() }
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let cancelledAt = Date()
    pending.cancel()
    do { _ = try await pending.value; fatalError("cancellation ignored") }
    catch is CancellationError { }
    check("cancellation returns without waiting for SDK callback") { expect(Date().timeIntervalSince(cancelledAt) < 1) }
    blocked.resolve(.success(2))

    _ = NSApplication.shared
    check("cancelled selection windows and content views are released") {
      for _ in 0..<20 {
        weak var weakWindow: NSWindow?
        weak var weakView: NSView?
        var calls = 0
        autoreleasepool {
          var window: NSWindow? = RegionPicker.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240)) { rect in
            expect(rect == nil)
            calls += 1
          }
          weakWindow = window
          weakView = window?.contentView
          let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window!.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
          window?.contentView?.keyDown(with: escape)
          window = nil
        }
        expect(calls == 1)
        expect(weakWindow == nil && weakView == nil, "selection retained after cancellation")
      }
    }

    check("menu icons support native template rendering in both states") {
      let idle = CaptureIcon.menuBar(recording: false)
      let active = CaptureIcon.menuBar(recording: true)
      expect(idle.isTemplate && active.isTemplate)
      expect(idle.size == NSSize(width: 18, height: 18))
      expect(idle.tiffRepresentation != active.tiffRepresentation)
    }
    check("settings bundle provides Noto Sans SC and outlined Lucide icons") {
      expect(SettingsStyle.nativeFont(13).familyName == "Noto Sans SC")
      for name in ["folder", "sliders-horizontal", "keyboard", "power", "type", "search", "rotate-ccw", "pencil", "circle-check"] {
        let image = NSImage(contentsOf: SettingsStyle.resourceURL.appendingPathComponent("Lucide/\(name).pdf"))
        expect(image != nil && image?.size == NSSize(width: 24, height: 24), "missing vector icon \(name)")
        if name == "power" || name == "rotate-ccw" {
          let bitmap = NSBitmapImageRep(data: image!.tiffRepresentation!)!
          expect(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 2 / 3)!.alphaComponent < 0.1,
            "outline icon has an accidental solid fill: \(name)")
        }
      }
    }

    check("shortcut recorder fits long states and preserves cancel, disable and modifier validation") {
      let view = ShortcutCaptureView(frame: .zero)
      let original = HotKeyAction.fullscreen.defaultCombo
      view.combo = original
      var commits = 0
      var committed: KeyCombo?
      view.onCommit = { value in commits += 1; committed = value; view.combo = value }
      @MainActor func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
          timestamp: 0, windowNumber: 0, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
      }
      @MainActor func fits() {
        let label = view.accessibilityValue() as? String ?? ""
        let width = (label as NSString).size(withAttributes: [.font: SettingsStyle.nativeFont(12.5, weight: 500)]).width
        expect(view.intrinsicContentSize.width >= width + 20)
      }
      _ = view.accessibilityPerformPress()
      fits()
      key(0, "a")
      expect(commits == 0 && view.accessibilityValue() as? String == "需含 ⌘/⌃/⌥")
      fits()
      key(53, "\u{1b}")
      expect(commits == 0 && view.combo == original)
      _ = view.accessibilityPerformPress()
      key(51, "\u{7f}")
      expect(commits == 1 && committed == nil)
      fits()
      _ = view.accessibilityPerformPress()
      key(49, " ", [.control, .option, .shift, .command])
      expect(commits == 2 && committed?.label == "⌃⌥⇧⌘空格")
      fits()
      view.onCommit = nil
    }

    check("settings defaults and legacy output folder survive migration without writes") {
      let storage = MemoryPreferences()
      let fresh = AppPreferences(storage: storage)
      expect(fresh.quality == .balanced && fresh.playSounds && fresh.revealAfterExport)
      expect(!fresh.watermarkEnabled && fresh.watermarkText.isEmpty)
      expect(storage.values.isEmpty)
      storage.values["outputDirectory"] = "/tmp/原有录制文件夹"
      storage.values["exportQuality"] = "unknown-future-value"
      let migrated = AppPreferences(storage: storage)
      expect(migrated.directory.path == "/tmp/原有录制文件夹")
      expect(migrated.quality == .balanced)
      expect(storage.values.count == 2)
    }

    check("settings persist and active recording retains its original snapshot") {
      let storage = MemoryPreferences()
      let preferences = AppPreferences(storage: storage)
      let active = preferences.snapshot
      preferences.directory = URL(fileURLWithPath: "/tmp/GIF output")
      preferences.quality = .clear
      preferences.playSounds = false
      preferences.revealAfterExport = false
      let reloaded = AppPreferences(storage: storage)
      expect(reloaded.directory.path == "/tmp/GIF output" && reloaded.quality == .clear)
      expect(!reloaded.playSounds && !reloaded.revealAfterExport)
      expect(active.directory != reloaded.directory && active.quality == .balanced)
      expect(active.playSounds && active.revealAfterExport)
    }

    check("reset restores defaults, persists them, and preserves an active recording snapshot") {
      let storage = MemoryPreferences()
      let preferences = AppPreferences(storage: storage)
      preferences.directory = URL(fileURLWithPath: "/tmp/custom")
      preferences.quality = .compact
      preferences.playSounds = false
      preferences.revealAfterExport = false
      preferences.watermarkEnabled = true
      preferences.watermarkText = "保留在正在录制的快照中"
      let active = preferences.snapshot
      preferences.resetAll()
      let reloaded = AppPreferences(storage: storage)
      expect(reloaded.directory == AppPreferences.defaultDirectory)
      expect(reloaded.quality == .balanced && reloaded.playSounds && reloaded.revealAfterExport)
      expect(!reloaded.watermarkEnabled && reloaded.watermarkText.isEmpty)
      expect(active.quality == .compact && active.effectiveWatermarkText == "保留在正在录制的快照中")
    }

    check("shortcut edits, disable, reload, and reset retain existing persistence keys") {
      let storage = MemoryPreferences()
      let shortcuts = ShortcutStore(storage: storage, registersGlobally: false)
      expect(storage.values.isEmpty)
      let custom = KeyCombo(keyCode: 15, modifiers: [.control, .option], display: "R")
      shortcuts.setCombo(custom, for: .fullscreen)
      shortcuts.setCombo(nil, for: .region)
      expect(storage.values["hotkey.region.key"] as? Int == -1)
      let reloaded = ShortcutStore(storage: storage, registersGlobally: false)
      expect(reloaded.combos[.fullscreen] == custom)
      expect(reloaded.combos.keys.contains(.region))
      expect((reloaded.combos[.region] ?? nil) == nil)
      reloaded.resetAll()
      let reset = ShortcutStore(storage: storage, registersGlobally: false)
      for action in HotKeyAction.allCases { expect(reset.combos[action] == action.defaultCombo) }
    }

    check("export presets reach the CLI and preserve explicit region framing") {
      let source = URL(fileURLWithPath: "/tmp/演示 录制.mov")
      let destination = URL(fileURLWithPath: "/tmp/自选文件夹/演示.gif")
      let expected = [(ExportQuality.clear, "0", "20", "600", "high"),
                      (.balanced, "1440", "12", "360", "default"),
                      (.compact, "720", "8", "180", "default")]
      for (quality, width, fps, cap, sensitivity) in expected {
        let settings = ExportSettings(directory: destination.deletingLastPathComponent(),
          quality: quality, playSounds: true, revealAfterExport: true)
        let args = settings.arguments(input: source, output: destination, regionPicked: false)
        expect(args == ["convert", source.path, "-o", destination.path, "--width", width,
                        "--fps", fps, "--max-frames", cap, "--sensitivity", sensitivity])
        expect(settings.arguments(input: source, output: destination, regionPicked: true)
          == args + ["--crop", "off"])
      }
    }

    check("watermark text persists while disabled and recording freezes its text") {
      let storage = MemoryPreferences()
      let preferences = AppPreferences(storage: storage)
      preferences.watermarkText = "  演示 👩🏽‍💻 ✨\n第二行  "
      expect(preferences.snapshot.effectiveWatermarkText == nil)
      preferences.watermarkEnabled = true
      let recording = preferences.snapshot
      expect(recording.effectiveWatermarkText == "演示 👩🏽‍💻 ✨ 第二行")
      preferences.watermarkText = "下次录制"
      preferences.watermarkEnabled = false
      let reloaded = AppPreferences(storage: storage)
      expect(!reloaded.watermarkEnabled && reloaded.watermarkText == "下次录制")
      expect(recording.effectiveWatermarkText == "演示 👩🏽‍💻 ✨ 第二行")
      preferences.watermarkEnabled = true
      preferences.watermarkText = " \n\t "
      expect(preferences.snapshot.effectiveWatermarkText == nil)
      expect(TextWatermark.normalized(String(repeating: "👨‍👩‍👧‍👦", count: 45)).count == 40)
    }

    check("watermark limit applies to writes and legacy values without splitting emoji") {
      let storage = MemoryPreferences()
      let emoji = "👩🏽‍💻"
      storage.values["watermarkText"] = String(repeating: emoji, count: 45)
      let preferences = AppPreferences(storage: storage)
      expect(preferences.watermarkText == String(repeating: emoji, count: 40))
      expect((storage.values["watermarkText"] as? String)?.count == 45, "reading must not rewrite preferences")
      preferences.watermarkText = String(repeating: emoji, count: 50)
      expect(preferences.watermarkText.count == 40)
      expect((storage.values["watermarkText"] as? String)?.count == 40)
      expect(AppPreferences(storage: storage).watermarkText == preferences.watermarkText)
    }

    try check("watermark renders Chinese and color emoji with translucent pixels") {
      let bitmap = try TextWatermark.bitmap("制作 / 小吴 👩🏽‍💻 ✨")
      var visible = 0, colored = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
          expect(color.alphaComponent <= 0.51, "watermark must stay translucent, including emoji")
          if color.alphaComponent > 0.1 {
            visible += 1
            if abs(color.redComponent - color.blueComponent) > 0.15 { colored += 1 }
          }
        }
      }
      expect(visible > 300 && colored > 20, "missing text or color emoji pixels")
      expect(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01)
      if let directory = ProcessInfo.processInfo.environment["S2G_TEST_ARTIFACT_DIR"] {
        try TextWatermark.png("制作 / 小吴 👩🏽‍💻 ✨").write(to:
          URL(fileURLWithPath: directory).appendingPathComponent("watermark.png"))
      }
    }

    check("login item enables once by default, with no registration in init") {
      let storage = MemoryPreferences()
      let service = MockLoginItem()
      let login = LaunchAtLogin(service: service, storage: storage)
      expect(service.registrationCount == 0 && storage.values.isEmpty)
      login.start()
      expect(login.isEnabled && service.registrationCount == 1)
      login.start()
      expect(service.registrationCount == 1)
      login.setEnabled(false)
      let reopened = LaunchAtLogin(service: service, storage: storage)
      reopened.start()
      expect(!reopened.isEnabled && service.registrationCount == 1 && service.unregistrationCount == 1)
    }

    check("external login-item changes remain authoritative after app restart") {
      let storage = MemoryPreferences()
      let service = MockLoginItem()
      let login = LaunchAtLogin(service: service, storage: storage)
      login.start()
      service.status = .requiresApproval
      login.refresh()
      expect(!login.isEnabled && login.needsApproval)
      login.start()
      expect(service.registrationCount == 1)
      service.status = .notRegistered
      LaunchAtLogin(service: service, storage: storage).start()
      expect(service.registrationCount == 1)
    }

    check("pending system approval is shown truthfully and not repeatedly registered") {
      let service = MockLoginItem()
      service.registeredStatus = .requiresApproval
      let login = LaunchAtLogin(service: service, storage: MemoryPreferences())
      login.start()
      expect(!login.isEnabled && login.needsApproval && login.detail.contains("尚未开启"))
      login.setEnabled(true)
      expect(service.registrationCount == 1)
      service.status = .enabled
      login.refresh()
      expect(login.isEnabled && !login.needsApproval)
    }

    check("failed login-item changes report errors without claiming success") {
      let storage = MemoryPreferences()
      let service = MockLoginItem()
      service.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "blocked"])
      let login = LaunchAtLogin(service: service, storage: storage)
      login.start()
      expect(!login.isEnabled && login.errorMessage?.contains("blocked") == true)
      login.start()
      expect(service.registrationCount == 1)
      service.failure = nil
      login.setEnabled(true)
      expect(login.isEnabled && login.errorMessage == nil)
      service.failure = NSError(domain: "test", code: 2)
      login.setEnabled(false)
      expect(login.isEnabled && login.errorMessage != nil)
    }

    check("existing login registration or disapproval is preserved on migration") {
      for status in [SMAppService.Status.enabled, .requiresApproval] {
        let service = MockLoginItem()
        service.status = status
        let login = LaunchAtLogin(service: service, storage: MemoryPreferences())
        login.start()
        expect(login.status == status && service.registrationCount == 0)
      }
    }
    print("\(passed) native regression checks passed")
  }
}
