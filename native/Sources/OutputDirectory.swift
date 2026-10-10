import AppKit

@MainActor
enum OutputDirectory {
  static func open() {
    // Resolve the current preference on every click, including after a folder change.
    let directory = AppPreferences.shared.directory
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
    guard exists && isDirectory.boolValue && NSWorkspace.shared.open(directory) else {
      DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = "无法打开 GIF 存储目录"
        alert.informativeText = "文件夹可能已移动或无法访问。请在设置中重新选择输出文件夹。\n\(directory.path)"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { SettingsWindowController.shared.open() }
      }
      return
    }
  }
}
