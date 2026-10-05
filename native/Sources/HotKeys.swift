import AppKit
import Carbon.HIToolbox
import Combine

// 全局快捷键：Carbon RegisterEventHotKey（系统级热键，无需辅助功能权限，
// 与 NSEvent 全局监听不同，后者要授权且无法保证按键到达）。
// 组合配置持久化在 UserDefaults，改完即存、立刻生效。

enum HotKeyAction: String, CaseIterable, Identifiable {
  case fullscreen
  case region
  case stop

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fullscreen: return "录制全屏"
    case .region: return "框选区域录制"
    case .stop: return "停止录制"
    }
  }

  /// Carbon EventHotKeyID.id（回调里靠它路由到 action）
  var carbonID: UInt32 {
    switch self {
    case .fullscreen: return 1
    case .region: return 2
    case .stop: return 3
    }
  }

  /// 默认组合：排在系统截屏键 ⌘⇧5 后面，好记且无系统冲突
  var defaultCombo: KeyCombo {
    switch self {
    case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: [.command, .shift], display: "6")
    case .region: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: [.command, .shift], display: "7")
    case .stop: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: [.command, .shift], display: "8")
    }
  }
}

/// 一个快捷键组合。modifiers 存的是 deviceIndependent 的交集（干净可比）。
struct KeyCombo: Equatable {
  var keyCode: UInt32
  var modifiers: NSEvent.ModifierFlags
  var display: String

  /// 菜单/设置里展示的样子，修饰键按 ⌃⌥⇧⌘ 习惯排序
  var label: String {
    var s = ""
    if modifiers.contains(.control) { s += "⌃" }
    if modifiers.contains(.option) { s += "⌥" }
    if modifiers.contains(.shift) { s += "⇧" }
    if modifiers.contains(.command) { s += "⌘" }
    return s + display
  }
}

final class HotKeyCenter {
  static let shared = HotKeyCenter()
  typealias Handler = (HotKeyAction) -> Void

  var onAction: Handler?
  private var refs: [HotKeyAction: EventHotKeyRef] = [:]
  private var installed = false

  func register(_ action: HotKeyAction, combo: KeyCombo) {
    unregister(action)
    installHandlerIfNeeded()

    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x73326766) /* 's2gf' */, id: action.carbonID)
    let status = RegisterEventHotKey(
      combo.keyCode,
      Self.carbonModifiers(combo.modifiers),
      id,
      GetApplicationEventTarget(),
      0,
      &ref)
    if status == noErr, let ref {
      refs[action] = ref
    } else {
      // 常见于组合键被其他 app 占用（errHotKeyExistsErr）
      dbg("hotkey register failed: \(action.rawValue) status=\(status)")
    }
  }

  func unregister(_ action: HotKeyAction) {
    if let ref = refs.removeValue(forKey: action) {
      UnregisterEventHotKey(ref)
    }
  }

  func unregisterAll() {
    for action in refs.keys { unregister(action) }
  }

  private func installHandlerIfNeeded() {
    guard !installed else { return }
    installed = true
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    // @convention(c) 闭包不能捕获上下文，靠 userData 把 self 带回来
    InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
      guard let event, let userData else { return noErr }
      var hotKeyID = EventHotKeyID()
      guard GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID) == noErr
      else { return noErr }
      let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
      if let action = HotKeyAction.allCases.first(where: { $0.carbonID == hotKeyID.id }) {
        DispatchQueue.main.async { center.onAction?(action) }
      }
      return noErr
    }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
  }

  // NSEvent.ModifierFlags 与 Carbon 修饰键常量必须显式映射：
  // .control 的 rawValue 自带两个 bit（0x40001），直接换算会错。
  private static func carbonModifiers(_ mods: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if mods.contains(.command) { carbon |= UInt32(cmdKey) }
    if mods.contains(.option) { carbon |= UInt32(optionKey) }
    if mods.contains(.control) { carbon |= UInt32(controlKey) }
    if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
  }
}

/// 快捷键配置的读写与注册。combos 的 value 是 Optional：nil = 用户显式禁用。
final class ShortcutStore: ObservableObject {
  static let shared = ShortcutStore()

  @Published private(set) var combos: [HotKeyAction: KeyCombo?] = [:]

  private init() {
    for action in HotKeyAction.allCases {
      combos[action] = Self.load(action)
    }
  }

  /// 启动时（或恢复默认后）按当前配置注册全部热键
  func registerAll() {
    for (action, combo) in combos {
      if let combo {
        HotKeyCenter.shared.register(action, combo: combo)
      } else {
        HotKeyCenter.shared.unregister(action)
      }
    }
  }

  func setCombo(_ combo: KeyCombo?, for action: HotKeyAction) {
    combos[action] = combo
    persist()
    registerAll()
  }

  func resetAll() {
    for action in HotKeyAction.allCases {
      combos[action] = action.defaultCombo
    }
    persist()
    registerAll()
  }

  // MARK: - UserDefaults

  private func persist() {
    let defaults = UserDefaults.standard
    for (action, combo) in combos {
      let key = "hotkey.\(action.rawValue)"
      if let combo {
        defaults.set(Int(combo.keyCode), forKey: key + ".key")
        defaults.set(UInt(combo.modifiers.rawValue), forKey: key + ".mods")
        defaults.set(combo.display, forKey: key + ".display")
      } else {
        // keyCode = -1 表示显式禁用（区别于「没写过」→ 用默认值）
        defaults.set(-1, forKey: key + ".key")
      }
    }
  }

  private static func load(_ action: HotKeyAction) -> KeyCombo? {
    let defaults = UserDefaults.standard
    let key = "hotkey.\(action.rawValue)"
    guard defaults.object(forKey: key + ".key") != nil else {
      return action.defaultCombo
    }
    let keyCode = defaults.integer(forKey: key + ".key")
    if keyCode < 0 { return nil }
    let modsRaw = defaults.object(forKey: key + ".mods") as? UInt
    let display = defaults.string(forKey: key + ".display")
      ?? defaultDisplay(forKeyCode: UInt32(max(0, keyCode)))
    return KeyCombo(
      keyCode: UInt32(max(0, keyCode)),
      modifiers: NSEvent.ModifierFlags(rawValue: modsRaw ?? 0),
      display: display)
  }

  /// 从 keyCode 反查显示名（只在读旧配置、display 缺失时兜底）
  static func defaultDisplay(forKeyCode keyCode: UInt32) -> String {
    if let name = keyNames[UInt16(keyCode)] { return name }
    return "Key\(keyCode)"
  }

  /// 常见特殊键的名字（字母数字直接用 charactersIgnoringModifiers，不用查表）
  static let keyNames: [UInt16: String] = {
    var names: [UInt16: String] = [:]
    let fKeys: [(UInt16, String)] = [
      (UInt16(kVK_F1), "F1"), (UInt16(kVK_F2), "F2"), (UInt16(kVK_F3), "F3"), (UInt16(kVK_F4), "F4"),
      (UInt16(kVK_F5), "F5"), (UInt16(kVK_F6), "F6"), (UInt16(kVK_F7), "F7"), (UInt16(kVK_F8), "F8"),
      (UInt16(kVK_F9), "F9"), (UInt16(kVK_F10), "F10"), (UInt16(kVK_F11), "F11"), (UInt16(kVK_F12), "F12"),
    ]
    for (code, name) in fKeys { names[code] = name }
    names[UInt16(kVK_Space)] = "空格"
    names[UInt16(kVK_LeftArrow)] = "←"
    names[UInt16(kVK_RightArrow)] = "→"
    names[UInt16(kVK_UpArrow)] = "↑"
    names[UInt16(kVK_DownArrow)] = "↓"
    names[UInt16(kVK_Return)] = "↩"
    names[UInt16(kVK_Tab)] = "⇥"
    return names
  }()

  /// 纯修饰键的 keyCode：录入时按住这些不算「按下了键」，继续等
  static let modifierKeyCodes: Set<UInt16> = [
    54, 55,  // 右/左 command
    58, 61,  // 右/左 option
    59, 62,  // 右/左 control
    56, 60,  // 右/左 shift
    63,      // fn
  ]
}
