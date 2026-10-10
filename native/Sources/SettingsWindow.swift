import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()
  private var window: NSWindow?
  private var directoryPanel: NSOpenPanel?

  func open() {
    DispatchQueue.main.async { self.showWindow() }
  }

  private func showWindow() {
    LaunchAtLogin.shared.refresh()
    if window == nil {
      let content = AppSettingsView(preferences: .shared, launchAtLogin: .shared,
        onChooseDirectory: { [weak self] in self?.chooseDirectory() })
      let w = Self.makeWindow(content: content)
      w.delegate = self
      window = w
    }
    adaptToScreen()
    NSApp.setActivationPolicy(.regular)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func adaptToScreen() {
    if let window, let screen = window.screen ?? NSScreen.main {
      window.maxSize = NSSize(width: SettingsStyle.width, height: screen.visibleFrame.height - 40)
      var frame = window.frame
      frame.size.height = min(frame.height, screen.visibleFrame.height - 40)
      frame.origin.y = max(screen.visibleFrame.minY + 20,
        min(frame.origin.y, screen.visibleFrame.maxY - frame.height - 20))
      window.setFrame(frame, display: true)
    }
  }

  nonisolated func windowDidChangeScreen(_ notification: Notification) {
    Task { @MainActor in self.adaptToScreen() }
  }

  static func makeWindow(content: AppSettingsView, height: CGFloat? = nil) -> NSWindow {
    let available = (NSScreen.main?.visibleFrame.height ?? 820) - 40
    let size = NSSize(width: SettingsStyle.width, height: min(height ?? 1230, available))
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    w.title = "screen2gif 设置"
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.appearance = NSAppearance(named: .aqua)
    w.backgroundColor = NSColor(SettingsStyle.background)
    w.contentView = NSHostingView(rootView: content.ignoresSafeArea())
    w.isReleasedWhenClosed = false
    w.minSize = NSSize(width: SettingsStyle.width, height: min(400, available))
    w.maxSize = NSSize(width: SettingsStyle.width, height: available)
    w.center()
    return w
  }

  private func chooseDirectory() {
    guard let window, directoryPanel == nil else { return }
    let panel = NSOpenPanel()
    panel.title = "选择输出文件夹"
    panel.prompt = "选为输出文件夹"
    panel.message = "录制的 GIF 将保存到你选定的文件夹。"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = AppPreferences.shared.directory
    directoryPanel = panel
    panel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = panel.url { AppPreferences.shared.directory = url }
      self?.directoryPanel = nil
    }
  }

  nonisolated func windowWillClose(_ notification: Notification) {
    Task { @MainActor in
      self.directoryPanel?.cancel(nil)
      self.directoryPanel = nil
      NSApp.setActivationPolicy(.accessory)
    }
  }
}

struct AppSettingsView: View {
  @ObservedObject private var preferences: AppPreferences
  @ObservedObject private var launchAtLogin: LaunchAtLogin
  @ObservedObject private var shortcuts: ShortcutStore
  @State private var search = ""
  @FocusState private var focusedField: Field?
  private enum Field { case search, watermark }
  let onChooseDirectory: () -> Void
  let onOpenDirectory: @MainActor () -> Void

  init(preferences: AppPreferences, launchAtLogin: LaunchAtLogin,
       shortcuts: ShortcutStore = .shared,
       onChooseDirectory: @escaping () -> Void,
       onOpenDirectory: @escaping @MainActor () -> Void = { OutputDirectory.open() }) {
    self.preferences = preferences
    self.launchAtLogin = launchAtLogin
    self.shortcuts = shortcuts
    self.onChooseDirectory = onChooseDirectory
    self.onOpenDirectory = onOpenDirectory
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("screen2gif 设置").font(SettingsStyle.font(13, weight: 600))
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(Color(hex: 0xEDEDEF))
        .accessibilityAddTraits(.isHeader)
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
          searchRow
          if visibleSections.contains(.output) {
            section("输出位置", icon: "folder") { outputCard }
          }
          if visibleSections.contains(.quality) {
            section("画质与体积", icon: "sliders-horizontal") { qualityCard }
          }
          if visibleSections.contains(.shortcuts) {
            ShortcutsSettingsView(store: shortcuts)
          }
          if visibleSections.contains(.startup) {
            section("启动与提示音", icon: "power") { startupCard }
          }
          if visibleSections.contains(.watermark) {
            section("文本水印", icon: "type") { watermarkCard }
          }
          if visibleSections.isEmpty {
            SettingsDetail(text: "未找到匹配的设置")
              .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
          }
          saveStatus
        }.padding(20)
      }
    }
    .font(SettingsStyle.font(13)).foregroundStyle(SettingsStyle.text)
    .background(SettingsStyle.background)
    .frame(width: SettingsStyle.width)
    .environment(\.colorScheme, .light)
    .onAppear { focusedField = nil }
  }

  private enum Section: CaseIterable { case output, quality, shortcuts, startup, watermark }
  private var visibleSections: [Section] {
    Section.allCases.filter { section in
      switch section {
      case .output: return matches("输出位置 输出文件夹 导出文件与 GIF 的保存位置 导出后在访达中显示 GIF 录制完成后自动打开所在文件夹 " + preferences.directory.path)
      case .quality: return matches("画质与体积 清晰优先 均衡 体积优先 最大宽度 帧率上限 预计体积 " + preferences.quality.detail)
      case .shortcuts: return matches("快捷键 录制全屏 框选区域录制 停止录制 恢复默认 Command Control Option Delete Esc")
      case .startup: return matches("启动与提示音 开机自启动 登录 Mac 后自动启动 常驻菜单栏 开始和结束时播放提示音 录制开始与结束时给出声音反馈")
      case .watermark: return matches("文本水印 在 GIF 右下角显示水印 固定小字 半透明 效果预览 emoji " + preferences.watermarkText)
      }
    }
  }

  private func matches(_ text: String) -> Bool {
    let terms = search.split(whereSeparator: { $0.isWhitespace })
    return terms.allSatisfy { text.localizedStandardContains(String($0)) }
  }

  private func section<Content: View>(_ title: String, icon: String,
                                      @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        SettingsIcon(name: icon)
        Text(title).font(SettingsStyle.font(13, weight: 600)).tracking(0.3)
          .accessibilityAddTraits(.isHeader)
      }
      content()
    }
  }

  private var searchRow: some View {
    HStack(spacing: 12) {
      HStack(spacing: 8) {
        SettingsIcon(name: "search", size: 14, color: SettingsStyle.secondary)
        TextField("", text: $search, prompt: Text("搜索设置项").foregroundStyle(SettingsStyle.secondary))
          .textFieldStyle(.plain).font(SettingsStyle.font(13))
          .focused($focusedField, equals: .search)
          .accessibilityLabel("搜索设置项")
          .onExitCommand { search = "" }
      }
      .padding(.horizontal, 10).frame(height: 32)
      .background(.white, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7)
        .strokeBorder(focusedField == .search ? SettingsStyle.accent : SettingsStyle.border, lineWidth: 1))
      Button(action: resetAll) {
        HStack(spacing: 6) {
          SettingsIcon(name: "rotate-ccw", size: 13, color: SettingsStyle.secondary)
          Text("恢复全部默认").font(SettingsStyle.font(12)).foregroundStyle(SettingsStyle.secondary)
        }.padding(.horizontal, 12).frame(height: 32)
      }.buttonStyle(SettingsButtonStyle()).fixedSize()
    }
  }

  private func resetAll() {
    preferences.resetAll()
    shortcuts.resetAll()
    setLoginEnabled(true)
  }

  private var outputCard: some View {
    SettingsCard {
      SettingsRow(title: "输出文件夹", detail: "导出文件与 GIF 的保存位置") {
        HStack(spacing: 8) {
          Button(action: onOpenDirectory) {
            Text((preferences.directory.path as NSString).abbreviatingWithTildeInPath)
              .font(SettingsStyle.font(12.5)).foregroundStyle(SettingsStyle.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.trailing)
          }
          .buttonStyle(.plain).frame(maxWidth: 230, alignment: .trailing)
          .help(preferences.directory.path + "\n在访达中显示")
          .accessibilityLabel("在访达中显示输出文件夹：" + preferences.directory.path)
          Button(action: onChooseDirectory) {
            Text("更改…").font(SettingsStyle.font(12, weight: 500))
              .padding(.horizontal, 11).padding(.vertical, 5)
          }.buttonStyle(SettingsButtonStyle(cornerRadius: 6)).fixedSize()
        }.fixedSize(horizontal: false, vertical: true)
      }
      SettingsDivider()
      switchRow("导出后在访达中显示 GIF", detail: "录制完成后自动打开所在文件夹",
        value: $preferences.revealAfterExport)
    }
  }

  private var qualityCard: some View {
    SettingsCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 3) {
          ForEach(ExportQuality.allCases) { quality in
            Button { preferences.quality = quality } label: {
              Text(quality.title)
                .font(SettingsStyle.font(12.5, weight: preferences.quality == quality ? 600 : 400))
                .foregroundStyle(preferences.quality == quality ? SettingsStyle.text : SettingsStyle.secondary)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background {
                  if preferences.quality == quality {
                    RoundedRectangle(cornerRadius: 6).fill(.white)
                      .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                  }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
              .accessibilityAddTraits(preferences.quality == quality ? [.isSelected] : [])
          }
        }.padding(3).background(SettingsStyle.panel, in: RoundedRectangle(cornerRadius: 8))
        SettingsDetail(text: preferences.quality.detail.replacingOccurrences(of: "\n", with: " · "))
      }.padding(.vertical, 12).padding(.horizontal, 14)
      SettingsDivider()
      HStack(spacing: 0) {
        metric(preferences.quality.width == 0 ? "原始像素" : "\(preferences.quality.width) px", title: "最大宽度")
        SettingsStyle.separator.frame(width: 1, height: 26)
        metric("\(preferences.quality.fps) fps", title: "帧率上限")
        SettingsStyle.separator.frame(width: 1, height: 26)
        metric("—", title: "预计体积")
          .help("体积取决于录制时长、区域和画面变化，录制并导出后才能确定。")
      }.padding(.horizontal, 2).padding(.vertical, 12)
    }
  }

  private func metric(_ value: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(SettingsStyle.font(13, weight: 600))
      Text(title).font(SettingsStyle.font(10.5)).foregroundStyle(SettingsStyle.secondary)
    }.padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value)
  }

  private func switchRow(_ title: String, detail: String, value: Binding<Bool>) -> some View {
    SettingsRow(title: title, detail: detail) {
      Toggle(title, isOn: value).toggleStyle(SettingsSwitchStyle())
    }
  }

  private func setLoginEnabled(_ enabled: Bool) {
    launchAtLogin.setEnabled(enabled)
    if enabled && launchAtLogin.needsApproval { launchAtLogin.openSystemSettings() }
  }

  private var startupCard: some View {
    SettingsCard {
      switchRow("开机自启动", detail: "登录 Mac 后自动启动，常驻菜单栏",
        value: Binding(get: { launchAtLogin.isEnabled }, set: setLoginEnabled))
      if launchAtLogin.needsApproval || launchAtLogin.errorMessage != nil || launchAtLogin.status == .notFound {
        VStack(alignment: .leading, spacing: 6) {
          SettingsDetail(text: launchAtLogin.detail)
          if launchAtLogin.needsApproval {
            Button("打开系统登录项设置") { launchAtLogin.openSystemSettings() }
              .buttonStyle(.link).font(SettingsStyle.font(11))
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14).padding(.bottom, 11)
      }
      SettingsDivider()
      switchRow("开始和结束时播放提示音", detail: "录制开始与结束时给出声音反馈", value: $preferences.playSounds)
    }
  }

  private var watermarkCard: some View {
    SettingsCard {
      switchRow("在 GIF 右下角显示水印", detail: "固定小字、半透明，随导出自动叠加", value: $preferences.watermarkEnabled)
      SettingsDivider()
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          SettingsIcon(name: "pencil", size: 13, color: SettingsStyle.secondary)
          TextField("制作 / 小吴 ✨", text: $preferences.watermarkText)
            .textFieldStyle(.plain).font(SettingsStyle.font(12.5))
            .focused($focusedField, equals: .watermark).accessibilityLabel("水印文字")
          Text("\(preferences.watermarkText.count) / \(TextWatermark.characterLimit)")
            .font(SettingsStyle.font(11)).foregroundStyle(SettingsStyle.secondary).fixedSize()
        }.padding(.horizontal, 10).frame(height: 32)
          .background(.white, in: RoundedRectangle(cornerRadius: 7))
          .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(focusedField == .watermark ? SettingsStyle.accent : SettingsStyle.border, lineWidth: 1))
        if preferences.watermarkEnabled {
          WatermarkPreview(text: preferences.snapshot.effectiveWatermarkText)
        }
        SettingsDetail(text: "仅支持文字和 emoji，最多 40 个字符；留空则不添加水印。")
      }.padding(.vertical, 12).padding(.horizontal, 14)
    }
  }

  private var saveStatus: some View {
    HStack(spacing: 8) {
      SettingsIcon(name: "circle-check", size: 14, color: SettingsStyle.accent)
      Text("所有更改已自动保存").font(SettingsStyle.font(11.5)).foregroundStyle(SettingsStyle.secondary)
      Spacer(minLength: 8)
      Text("screen2gif \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (macOS)")
        .font(SettingsStyle.font(10.5)).foregroundStyle(Color(hex: 0x9A9DA3))
    }.padding(2)
  }
}

struct WatermarkPreview: View {
  let text: String?

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(colors: [Color(hex: 0x20242C), Color(hex: 0x3B414E)],
        startPoint: .leading, endPoint: .trailing)
      RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.13))
        .frame(width: 96, height: 9).offset(x: 14, y: 16)
      RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08))
        .frame(width: 150, height: 9).offset(x: 14, y: 33)
      VStack(alignment: .leading) {
        Text("效果预览").font(SettingsStyle.font(10.5)).foregroundStyle(.white.opacity(0.54))
        Spacer()
        if let text {
          Text(text).font(SettingsStyle.font(12, weight: 500)).foregroundStyle(.white).opacity(0.62)
            .lineLimit(1).minimumScaleFactor(0.3)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }.padding(12)
    }.frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text.map { "右下角水印预览：\($0)" } ?? "未添加水印")
  }
}

struct ShortcutsSettingsView: View {
  @ObservedObject var store: ShortcutStore

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        SettingsIcon(name: "keyboard")
        Text("快捷键").font(SettingsStyle.font(13, weight: 600)).tracking(0.3)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button { store.resetAll() } label: {
          Text("恢复默认").font(SettingsStyle.font(11, weight: 500)).foregroundStyle(SettingsStyle.accent)
            .padding(.vertical, 3).padding(.horizontal, 10)
        }.buttonStyle(SettingsButtonStyle(capsule: true)).accessibilityLabel("恢复默认快捷键")
      }
      SettingsCard {
        ForEach(HotKeyAction.allCases) { action in
          VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: action.title) {
              ShortcutRecorderField(combo: store.combos[action] ?? nil, label: action.title) {
                store.setCombo($0, for: action)
              }.fixedSize()
            }
            if store.conflicts.contains(action) {
              Text("此快捷键已被占用，请更换。")
                .font(SettingsStyle.font(11)).foregroundStyle(.red)
                .padding(.horizontal, 14).padding(.bottom, 11)
            }
          }
          SettingsDivider()
        }
        SettingsDetail(text: "点击输入框录入组合键；Delete 禁用，Esc 取消。组合需包含 Command / Control / Option。")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 11).padding(.horizontal, 14)
      }
    }
  }
}

// MARK: - 快捷键录入控件

struct ShortcutRecorderField: NSViewRepresentable {
  var combo: KeyCombo?
  var label: String
  var onChange: (KeyCombo?) -> Void

  func makeNSView(context: Context) -> ShortcutCaptureView {
    let view = ShortcutCaptureView()
    view.combo = combo
    view.onCommit = onChange
    view.setAccessibilityLabel(label)
    return view
  }

  func updateNSView(_ view: ShortcutCaptureView, context: Context) {
    view.combo = combo
    view.onCommit = onChange
    view.setAccessibilityLabel(label)
    view.needsDisplay = true
  }
}

/// 自绘的「按钮式」录入框：点击进入录入态，keyDown 里截组合键。
/// 不用 SwiftUI 的 onKeyPress 是因为菜单栏 app 的设置窗口焦点管理简单直接，NSView 一层就够。
final class ShortcutCaptureView: NSView {
  var combo: KeyCombo? {
    didSet { invalidateIntrinsicContentSize(); setAccessibilityValue(displayText) }
  }
  var onCommit: ((KeyCombo?) -> Void)?

  private var recording = false {
    didSet { invalidateIntrinsicContentSize(); setAccessibilityValue(displayText) }
  }
  private var showNeedModifierHint = false {
    didSet { invalidateIntrinsicContentSize(); setAccessibilityValue(displayText) }
  }

  private var displayText: String {
    if recording { return showNeedModifierHint ? "需含 ⌘/⌃/⌥" : "按下新组合键…" }
    return combo?.label ?? "未设置（已禁用）"
  }

  override var intrinsicContentSize: NSSize {
    let textSize = (displayText as NSString).size(withAttributes: [.font: SettingsStyle.nativeFont(12.5, weight: 500)])
    return NSSize(width: max(54, ceil(textSize.width) + 20), height: max(23, ceil(textSize.height) + 8))
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityHelp("点击输入框录入组合键；Delete 禁用，Esc 取消。组合需包含 Command / Control / Option。")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func accessibilityPerformPress() -> Bool {
    beginRecording()
    return true
  }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    if recording {
      NSColor(SettingsStyle.accent).withAlphaComponent(0.10).setFill()
    } else {
      NSColor(SettingsStyle.keycap).setFill()
    }
    path.fill()
    NSColor(recording || window?.firstResponder === self ? SettingsStyle.accent : SettingsStyle.keycapBorder).setStroke()
    path.lineWidth = 1
    path.stroke()

    let text = displayText
    let color = NSColor(combo != nil || recording ? SettingsStyle.text : SettingsStyle.secondary)
    let font = SettingsStyle.nativeFont(12.5, weight: 500)
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
    beginRecording()
  }

  private func beginRecording() {
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
    if !recording, event.keyCode == 36 || event.keyCode == 49 {
      beginRecording()
      return
    }
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
