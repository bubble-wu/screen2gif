import AppKit
import SwiftUI

// 快捷键设置窗口。菜单栏 app 没有主窗口，按需创建一个普通 NSWindow
// （需要成为 key window 才能捕获键盘录入）。

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()
  private var window: NSWindow?

  func open() {
    if window == nil {
      let content = ShortcutsSettingsView()
        .frame(width: 340)
      let host = NSHostingView(rootView: content)
      let w = NSWindow(
        contentRect: NSRect(origin: .zero, size: host.fittingSize),
        styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      w.title = "快捷键设置"
      w.contentView = host
      w.isReleasedWhenClosed = false   // 关掉只隐藏，下次秒开
      w.standardWindowButton(.miniaturizeButton)?.isHidden = true
      w.standardWindowButton(.zoomButton)?.isHidden = true
      w.delegate = self
      window = w
    }
    window?.center()
    // 菜单栏 app（.accessory）直接 activate 经常不生效，键盘事件进不来，
    // 快捷键录入就没法用。临时切 .regular 拿焦点，窗口关闭时切回。
    NSApp.setActivationPolicy(.regular)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // 关窗（红点或 Cmd+W）回到 .accessory：去 Dock 化，回到纯菜单栏形态
  nonisolated func windowWillClose(_ notification: Notification) {
    Task { @MainActor in
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

struct ShortcutsSettingsView: View {
  @ObservedObject private var store = ShortcutStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("全局快捷键")
        .font(.headline)

      VStack(spacing: 8) {
        ForEach(HotKeyAction.allCases) { action in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(action.title)
              Spacer()
              ShortcutRecorderField(combo: store.combos[action] ?? nil) {
                store.setCombo($0, for: action)
              }
              .frame(width: 110, height: 24)
            }
            if store.conflicts.contains(action) {
              Text("注册失败：组合可能已被其他应用占用，请更换")
                .font(.caption)
                .foregroundStyle(.red)
            }
          }
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 4) {
        Text("点击右侧按钮后按下新组合键（需含 ⌘/⌃/⌥ 之一）；按 ⌫ 禁用，Esc 取消。")
        Text("与其他应用冲突时会注册失败，换个组合即可。")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("恢复默认") { store.resetAll() }
      }
    }
    .padding(20)
  }
}

// MARK: - 快捷键录入控件

struct ShortcutRecorderField: NSViewRepresentable {
  var combo: KeyCombo?
  var onChange: (KeyCombo?) -> Void

  func makeNSView(context: Context) -> ShortcutCaptureView {
    let view = ShortcutCaptureView()
    view.combo = combo
    view.onCommit = onChange
    return view
  }

  func updateNSView(_ view: ShortcutCaptureView, context: Context) {
    view.combo = combo
    view.needsDisplay = true
  }
}

/// 自绘的「按钮式」录入框：点击进入录入态，keyDown 里截组合键。
/// 不用 SwiftUI 的 onKeyPress 是因为菜单栏 app 的设置窗口焦点管理简单直接，NSView 一层就够。
final class ShortcutCaptureView: NSView {
  var combo: KeyCombo?
  var onCommit: ((KeyCombo?) -> Void)?

  private var recording = false
  private var showNeedModifierHint = false

  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
    if recording {
      NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
    } else {
      NSColor.controlColor.setFill()
    }
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1
    path.stroke()

    let text: String
    var color = NSColor.labelColor
    if recording {
      text = showNeedModifierHint ? "需含 ⌘/⌃/⌥" : "按下新组合键…"
      color = .labelColor
    } else if let combo {
      text = combo.label
    } else {
      text = "未设置（已禁用）"
      color = .tertiaryLabelColor
    }
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(
      at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
      withAttributes: attrs)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    recording = true
    showNeedModifierHint = false
    needsDisplay = true
  }

  override func resignFirstResponder() -> Bool {
    recording = false
    showNeedModifierHint = false
    needsDisplay = true
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard recording else { return }

    if event.keyCode == 53 {  // Esc：取消录入，不改配置
      recording = false
      showNeedModifierHint = false
      needsDisplay = true
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {  // ⌫ / Del：禁用
      recording = false
      showNeedModifierHint = false
      needsDisplay = true
      onCommit?(nil)
      return
    }
    // 纯修饰键按下不算数，继续等真正的键
    guard !ShortcutStore.modifierKeyCodes.contains(event.keyCode) else { return }

    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
      // 不带功能修饰键的组合会吞掉正常打字，拒绝
      showNeedModifierHint = true
      needsDisplay = true
      return
    }

    let display = Self.displayString(event)
    recording = false
    showNeedModifierHint = false
    needsDisplay = true
    onCommit?(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods, display: display))
  }

  /// 从事件取显示名：可打印字符直接用，功能键查表
  private static func displayString(_ event: NSEvent) -> String {
    if let chars = event.charactersIgnoringModifiers,
       let first = chars.first,
       first.unicodeScalars.allSatisfy({ scalar in
         scalar.value > 32 && !(0xF700...0xF8FF).contains(scalar.value)
       }) {
      return String(first).uppercased()
    }
    if let name = ShortcutStore.keyNames[event.keyCode] { return name }
    return "Key\(event.keyCode)"
  }
}
