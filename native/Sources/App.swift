import ScreenCaptureKit
import SwiftUI

// GUI 启动时 stderr 落到 /dev/null；从终端直接跑 app 二进制就能看到，用于调试。
func dbg(_ message: String) {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

@MainActor
final class Model: ObservableObject {
  enum Phase { case idle, picking, starting, recording, converting }

  @Published var phase: Phase = .idle
  @Published var statusLine = ""
  @Published var needsPermission = false
  /// 启动自检出缺失的依赖（node/ffmpeg/ffprobe），菜单里给一键安装
  @Published var missingDeps: [String] = []
  /// 「安装依赖」进行中：隐藏按钮 + 拦住重复点击（连点会起两个 brew）
  @Published private(set) var installing = false

  private let recorder = Recorder()
  // 圈选已经表达了取景意图，转码时跳过 auto 裁剪，所见即所得
  private var regionPicked = false
  private var recordingSettings = AppPreferences.shared.snapshot
  /// stop() 后等 didFinish 的兜底：采集会话卡死时回调永远不来，
  /// phase 会停在 converting，菜单回不到可录制状态。自测路径有 20s 超时，正式 UI 也得有。
  private var stopWatchdog: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var activeID: UUID?

  init() {
    recorder.onFinished = { [weak self] mov in
      self?.handleRecordingFinished(mov)
    }
    recorder.onFailed = { [weak self] error in
      self?.fail(error)
    }

    // 全局快捷键（可在「设置…」里改）
    ShortcutStore.shared.registerAll()
    HotKeyCenter.shared.onAction = { [weak self] action in
      DispatchQueue.main.async {
        guard let self else { return }
        switch action {
        case .fullscreen: self.startFullscreen()
        case .region: self.startRegion()
        case .stop: self.stop()
        }
      }
    }

    // 启动即自检：权限/依赖的问题当场暴露在菜单里，
    // 别让用户第一次录制失败才知道还要授权、装依赖
    Task { @MainActor in
      do {
        let content = try await captureWithDeadline(seconds: 60) { try await SCShareableContent.current }
        if content.displays.isEmpty { needsPermission = true; statusLine = "缺少屏幕录制权限" }
      }
      catch {
        if Self.isPermissionError(error) {
          needsPermission = true
          statusLine = "缺少屏幕录制权限"
        }
      }
    }
    missingDeps = Deps.missing()
  }

  /// 菜单里的「安装缺失依赖」：跑 brew install（进度不透传，只留报错尾巴），
  /// 装完重查，成功与否都更新菜单状态
  func installDeps() {
    guard !installing, !missingDeps.isEmpty else { return }
    guard let brew = Deps.brewURL else {
      statusLine = "未找到 Homebrew，请先到 brew.sh 安装"
      if let url = URL(string: "https://brew.sh") { NSWorkspace.shared.open(url) }
      return
    }
    // ffprobe 随 ffmpeg 一起装
    let specs = Array(Set(missingDeps.map { $0 == "ffprobe" ? "ffmpeg" : $0 })).sorted()
    installing = true
    statusLine = "安装依赖中（可能需要几分钟）…"
    let process = Process()
    process.executableURL = brew
    process.arguments = ["install"] + specs
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = Converter.searchPATH()
    process.environment = env
    // brew 的进度写在 stderr，量可能很大：stdout 直接丢弃；stderr 不能等退出后
    // 才读——输出超过管道缓冲（64KB）会把 brew 永久卡死，必须边跑边排空。
    process.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    let tail = OutputTail()
    process.standardError = errPipe
    do { try process.run() }
    catch {
      installing = false
      statusLine = "无法启动 brew：\(error.localizedDescription)"
      return
    }
    errPipe.fileHandleForReading.readabilityHandler = { fh in
      let chunk = fh.availableData
      if chunk.isEmpty { fh.readabilityHandler = nil } else { tail.append(chunk) }
    }
    process.terminationHandler = { [weak self] proc in
      DispatchQueue.main.async {
        guard let self else { return }
        self.installing = false
        self.missingDeps = Deps.missing()
        if proc.terminationStatus == 0 && self.missingDeps.isEmpty {
          self.statusLine = "依赖已就绪"
        } else {
          let text = tail.lastMessage() ?? "exit \(proc.terminationStatus)"
          self.statusLine = self.missingDeps.isEmpty
            ? "安装失败：\(text)"
            : "部分依赖仍缺失（\(self.missingDeps.joined(separator: " "))）：\(text)"
        }
      }
    }
  }

  func startFullscreen() {
    guard phase == .idle else { return }
    start(region: nil)
  }

  func startRegion() {
    guard phase == .idle else { return }
    phase = .picking
    RegionPicker.pick { [weak self] rect in
      DispatchQueue.main.async {
        guard let self else { return }
        if let rect {
          self.start(region: rect)
        } else {
          self.phase = .idle
          self.statusLine = "已取消框选"
        }
      }
    }
  }

  func stop() {
    if phase == .starting {
      activeID = nil
      startupTask?.cancel()
      startupTask = nil
      recorder.abort()
      RecordingOverlay.hide()
      phase = .idle
      statusLine = "已取消开始录制"
      return
    }
    guard phase == .recording else { return }
    phase = .converting
    statusLine = "收尾中…"
    recorder.stop()
    RecordingOverlay.hide()
    // 兜底：stopCapture 后 didFinish 正常百毫秒级就来，30 秒还没到就是会话卡死。
    // 转码阶段不设超时——时长随录制时长增长，固定值会误杀长录制。
    let id = activeID
    stopWatchdog = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled, self.activeID == id else { return }
      self.fail(StopTimeout())
    }
  }

  private func start(region: CGRect?) {
    let mov = FileManager.default.temporaryDirectory
      .appendingPathComponent("s2g-\(UUID().uuidString).mov")
    let id = UUID()
    activeID = id
    phase = .starting
    statusLine = "准备录制中…"
    regionPicked = (region != nil)
    recordingSettings = AppPreferences.shared.snapshot
    let focused = CaptureResult<Void>()
    if region == nil { focused.resolve(.success(())) }
    let overlayWindows = RecordingOverlay.show(
      region: region,
      onStop: { [weak self] in self?.stop() },
      onFocused: { focused.resolve(.success(())) })
    let excludedIDs = overlayWindows.map(\.windowNumber)
    startupTask = Task { @MainActor in
      do {
        try await recorder.start(region: region, to: mov, excluding: excludedIDs)
        let startedAt = Date()
        // Both the writer and focus animation must be ready before the cue.
        try await captureWithDeadline(seconds: 2) { try await focused.value() }
        guard !Task.isCancelled, activeID == id, phase == .starting else { return }
        phase = .recording
        startupTask = nil
        needsPermission = false
        RecordingOverlay.markRecording(startedAt: startedAt)
        cue("Glass")
      } catch {
        guard activeID == id else { return }
        fail(error)
      }
    }
  }

  private func handleRecordingFinished(_ mov: URL) {
    guard let id = activeID, phase == .recording || phase == .converting else { return }
    stopWatchdog?.cancel()
    stopWatchdog = nil
    RecordingOverlay.hide()
    cue("Tink")
    phase = .converting
    statusLine = "转码中…"
    dbg("recording finished: \(mov.path)")
    let settings = recordingSettings
    Converter.convert(mov: mov, regionPicked: regionPicked, settings: settings) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.activeID == id else { return }
        switch result {
        case .success(let gif):
          dbg("converted: \(gif.path)")
          try? FileManager.default.removeItem(at: mov)
          self.activeID = nil
          self.phase = .idle
          self.statusLine = "已保存 \(gif.lastPathComponent)"
          if settings.revealAfterExport { NSWorkspace.shared.activateFileViewerSelecting([gif]) }
        case .failure(let error):
          self.fail(error)
        }
      }
    }
  }

  private func fail(_ error: Error) {
    dbg("fail: \(error.localizedDescription)")
    activeID = nil
    startupTask?.cancel()
    startupTask = nil
    recorder.abort()
    stopWatchdog?.cancel()
    stopWatchdog = nil
    RecordingOverlay.hide()
    phase = .idle
    statusLine = error.localizedDescription
    needsPermission = Self.isPermissionError(error)
  }

  // 与 CLI 一致的提示音：开始 Glass，结束 Tink
  private func cue(_ name: String) {
    guard recordingSettings.playSounds else { return }
    NSSound(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff"), byReference: true)?.play()
  }

  // 未授权屏幕录制时 SCShareableContent 直接抛错，得把用户领到设置面板
  private static func isPermissionError(_ error: Error) -> Bool {
    if let wrapped = error as? Recorder.RecorderError {
      switch wrapped {
      case .noDisplay: return true
      case .queryContentFailed(let inner), .startFailed(let inner), .addOutputFailed(let inner):
        return isPermissionError(inner)
      }
    }
    let ns = error as NSError
    if ns.domain == "SCStreamErrorDomain", ns.code == -3801 { return true }
    let text = ns.localizedDescription
    return text.contains("TCC") || text.contains("denied") || text.contains("拒绝")
  }

  func openScreenCaptureSettings() {
    needsPermission = false
    statusLine = "授权后如仍失败，请退出并重新打开本 app"
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }
}

struct MenuContent: View {
  @EnvironmentObject var model: Model
  @ObservedObject private var shortcuts = ShortcutStore.shared

  /// 菜单里展示快捷键提示（如 "⌘⇧6"）；被禁用则不显示
  private func hint(_ action: HotKeyAction) -> String {
    guard let combo = shortcuts.combos[action] ?? nil else { return "" }
    return "  " + combo.label
  }

  var body: some View {
    switch model.phase {
    case .idle:
      Text(model.statusLine.isEmpty ? "screen2gif" : model.statusLine)
      if model.needsPermission {
        Button("打开屏幕录制设置…") { model.openScreenCaptureSettings() }
      }
      if !model.missingDeps.isEmpty && !model.installing {
        Button("安装缺失依赖（\(model.missingDeps.sorted().joined(separator: " "))）…") {
          model.installDeps()
        }
      }
      if !shortcuts.conflicts.isEmpty {
        Text("⚠ 有快捷键注册失败（可能被其他应用占用），可在「设置…」更换")
      }
      Divider()
      Button("录制全屏\(hint(.fullscreen))") { model.startFullscreen() }
      Button("框选区域录制…\(hint(.region))") { model.startRegion() }
      Divider()
      Button("打开 GIF 存储目录") { OutputDirectory.open() }
      Button("设置…") { SettingsWindowController.shared.open() }
      Divider()
      Button("退出") { NSApplication.shared.terminate(nil) }
    case .picking:
      Text("在屏幕上拖拽框选…（Esc 取消）")
    case .starting:
      Text("准备录制中…")
      Button("取消") { model.stop() }
    case .recording:
      Text("● 录制中 · 状态条可直接停止")
      Button("停止录制并转码\(hint(.stop))") { model.stop() }
    case .converting:
      Text(model.statusLine)
    }
  }
}

/// stop() 收尾的兜底错误：SCRecordingOutput 的 didFinish 不来（采集会话卡死）。
/// 恢复手段与 README 故障排查表一致：killall ControlCenter 或注销重登。
private struct StopTimeout: LocalizedError {
  var errorDescription: String? {
    "停止录制超时（采集会话无响应）。可运行 killall ControlCenter 恢复后重录"
  }
}

/// installDeps 的 brew stderr 收集器：在 readabilityHandler 的后台队列上追加，
/// 锁保护跨线程读写；只在退出后取最后一条非空行用于报错（brew 把错误写在末尾）。
final class OutputTail: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""

  func append(_ data: Data) {
    guard let chunk = String(data: data, encoding: .utf8) else { return }
    lock.lock(); text += chunk; lock.unlock()
  }

  func lastMessage() -> String? {
    lock.lock(); defer { lock.unlock() }
    return text.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .last(where: { !$0.isEmpty })
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchAtLogin.shared.start()
    if CommandLine.arguments.contains("--settings") { SettingsWindowController.shared.open() }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    LaunchAtLogin.shared.refresh()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    SettingsWindowController.shared.open()
    return true
  }
}

@main
struct Screen2GifApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = Model()

  init() {
    if let seconds = Self.selfTestSeconds() {
      Self.runSelfTest(seconds: seconds, region: Self.selfTestRect())
      exit(0)
    }
    if let rect = Self.focusTestRect() {
      Self.runFocusTest(rect: rect)
      exit(0)
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent().environmentObject(model)
    } label: {
      Image(nsImage: CaptureIcon.menuBar(recording: model.phase == .recording))
        .accessibilityLabel("screen2gif")
    }
  }

  // --capture-test <秒> [--rect x,y,w,h]：无 UI 录一段，验证采集层与区域裁剪数学
  //（首次会触发屏幕录制授权弹窗）
  private static func selfTestSeconds() -> Double? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--capture-test"), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
  }

  // --focus-test x,y,w,h：只挂 overlay 跑对焦动画（不含采集），
  // 用来无鼠标地验证虚化开场与角标渲染
  private static func focusTestRect() -> CGRect? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--focus-test"), i + 1 < args.count else { return nil }
    let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
  }

  private static func runFocusTest(rect: CGRect) {
    _ = NSApplication.shared
    _ = RecordingOverlay.show(
      region: rect,
      onStop: {},
      onFocused: { dbg("focused") })
    // 动画靠主 runloop 驱动，不能 Thread.sleep 卡死
    let end = Date().addingTimeInterval(2.0)
    while Date() < end {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    RecordingOverlay.hide()
  }

  private static func selfTestRect() -> CGRect? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--rect"), i + 1 < args.count else { return nil }
    let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
  }

  private static func runSelfTest(seconds: Double, region: CGRect?) {
    var finished = false
    var exitStatus: Int32 = 1
    let recorder = Recorder()
    let result = CaptureResult<URL>()
    recorder.onFinished = { result.resolve(.success($0)) }
    recorder.onFailed = { result.resolve(.failure($0)) }
    let mov = FileManager.default.temporaryDirectory
      .appendingPathComponent("s2g-selftest-\(UUID().uuidString).mov")
    Task { @MainActor in
      defer { finished = true }
      do {
        try await recorder.start(region: region, to: mov)
        dbg("recording \(seconds)s")
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        recorder.stop()
        let url = try await captureWithDeadline(seconds: 30) { try await result.value() }
        print("MOV \(url.path)")
        exitStatus = 0
      } catch {
        recorder.abort()
        dbg("ERROR: \(error.localizedDescription)")
      }
    }
    // SDK delegates and session state run on MainActor; keep its run loop alive.
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    exit(exitStatus)
  }
}
