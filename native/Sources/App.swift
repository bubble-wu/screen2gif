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
  /// 菜单里显示的输出目录（「输出位置：xxx」），选完即刷新
  @Published private(set) var outputLabel = ""

  private let recorder = Recorder()
  // 圈选已经表达了取景意图，转码时跳过 auto 裁剪，所见即所得
  private var regionPicked = false

  init() {
    recorder.onFinished = { [weak self] mov in
      DispatchQueue.main.async { self?.handleRecordingFinished(mov) }
    }
    recorder.onFailed = { [weak self] error in
      DispatchQueue.main.async { self?.fail(error) }
    }

    // 全局快捷键（可在「快捷键设置…」里改）
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
      do { _ = try await SCShareableContent.current }
      catch {
        if Self.isPermissionError(error) {
          needsPermission = true
          statusLine = "缺少屏幕录制权限"
        }
      }
    }
    missingDeps = Deps.missing()
    outputLabel = Self.describeOutputDirectory(Converter.outputDirectory())
  }

  /// 菜单里的「输出位置…」：目录选择面板，存 UserDefaults，下次录制即生效。
  /// 面板里能新建目录；选到的目录就算之后被删，CLI 也会 -o mkdir 自动重建
  func chooseOutputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = Converter.outputDirectory()
    panel.message = "录制的 GIF 保存到这里"
    if panel.runModal() == .OK, let url = panel.url {
      UserDefaults.standard.set(url.path, forKey: Converter.outputDirKey)
      outputLabel = Self.describeOutputDirectory(url)
    }
  }

  /// 目录的菜单显示：桌面写「桌面」，home 下缩成 ~/…，其余显示完整路径
  private static func describeOutputDirectory(_ url: URL) -> String {
    let fm = FileManager.default
    if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
       url.path == desktop.path { return "桌面" }
    let home = fm.homeDirectoryForCurrentUser.path
    if url.path == home { return "~" }
    if url.path.hasPrefix(home + "/") { return "~" + url.path.dropFirst(home.count) }
    return url.path
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
    guard phase == .recording else { return }
    phase = .converting
    statusLine = "收尾中…"
    recorder.stop()
  }

  private func start(region: CGRect?) {
    let mov = FileManager.default.temporaryDirectory
      .appendingPathComponent("s2g-\(UUID().uuidString).mov")
    // 先把 overlay 挂出来：Recorder 要拿它的窗口从采集里剔除（全屏时不这么做会入镜）
    let overlayWindows = RecordingOverlay.show(
      region: region,
      onStop: { [weak self] in self?.stop() },
      // 框选：对焦动画完成（画面清晰）时播 Glass——「清晰了 = 开始了」
      onFocused: { [weak self] in
        guard let self, self.phase == .starting || self.phase == .recording else { return }
        Self.cue("Glass")
      })
    // Recorder.start 已是 async：主线程不再被 SCShareableContent 查询/
    // startCapture 阻塞，对焦快照的 Task 与开录并行推进，提示音不再漂移
    phase = .starting
    statusLine = ""
    Task { @MainActor in
      do {
        // windowNumber 在 MainActor 上取好再传进去：Recorder.start 是 nonisolated
        // async，直接摸 NSWindow 会撞并发检查
        let excludedIDs = overlayWindows.map(\.windowNumber)
        try await recorder.start(region: region, to: mov, excluding: excludedIDs)
        regionPicked = (region != nil)
        phase = .recording
        needsPermission = false
        if region == nil {
          Self.cue("Glass")
        }
      } catch {
        RecordingOverlay.hide()
        fail(error)
      }
    }
  }

  private func handleRecordingFinished(_ mov: URL) {
    RecordingOverlay.hide()
    Self.cue("Tink")
    phase = .converting
    statusLine = "转码中…"
    dbg("recording finished: \(mov.path)")
    Converter.convert(mov: mov, regionPicked: regionPicked) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let gif):
          dbg("converted: \(gif.path)")
          try? FileManager.default.removeItem(at: mov)
          self.phase = .idle
          self.statusLine = "已保存 \(gif.lastPathComponent)"
          NSWorkspace.shared.activateFileViewerSelecting([gif])
        case .failure(let error):
          self.fail(error)
        }
      }
    }
  }

  private func fail(_ error: Error) {
    dbg("fail: \(error.localizedDescription)")
    RecordingOverlay.hide()
    phase = .idle
    statusLine = error.localizedDescription
    needsPermission = Self.isPermissionError(error)
  }

  // 与 CLI 一致的提示音：开始 Glass，结束 Tink
  private static func cue(_ name: String) {
    NSSound(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff"), byReference: true)?.play()
  }

  // 未授权屏幕录制时 SCShareableContent 直接抛错，得把用户领到设置面板
  private static func isPermissionError(_ error: Error) -> Bool {
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
        Text("⚠ 有快捷键注册失败（可能被其他应用占用），可在「快捷键设置…」更换")
      }
      Divider()
      Button("录制全屏\(hint(.fullscreen))") { model.startFullscreen() }
      Button("框选区域录制…\(hint(.region))") { model.startRegion() }
      Divider()
      Button("输出位置：\(model.outputLabel)…") { model.chooseOutputDirectory() }
      Button("快捷键设置…") { SettingsWindowController.shared.open() }
      Divider()
      Button("退出") { NSApplication.shared.terminate(nil) }
    case .picking:
      Text("在屏幕上拖拽框选…（Esc 取消）")
    case .starting:
      Text("正在开始录制…")
    case .recording:
      Text("● 录制中 · 状态条可直接停止")
      Button("停止录制并转码\(hint(.stop))") { model.stop() }
    case .converting:
      Text(model.statusLine)
    }
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

@main
struct Screen2GifApp: App {
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
      Image(systemName: model.phase == .recording ? "record.circle.fill" : "record.circle")
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
    let recorder = Recorder()
    let done = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>?
    recorder.onFinished = { url in result = .success(url); done.signal() }
    recorder.onFailed = { error in result = .failure(error); done.signal() }

    let mov = FileManager.default.temporaryDirectory
      .appendingPathComponent("s2g-selftest.mov")
    // start 已是 async；自测在 runloop 之外跑，用信号量桥回同步。
    // 必须 Task.detached：这里处于 @MainActor 的 App.init，普通 Task 会
    // 继承 MainActor 排进主队列，而主线程正阻塞在下面的 wait() 上——死锁。
    let startSem = DispatchSemaphore(value: 0)
    var startError: Error?
    Task.detached {
      do { try await recorder.start(region: region, to: mov) }
      catch { startError = error }
      startSem.signal()
    }
    startSem.wait()
    if let startError {
      FileHandle.standardError.write("ERROR: \(startError.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    }
    FileHandle.standardError.write("recording \(seconds)s\n".data(using: .utf8)!)
    Thread.sleep(forTimeInterval: seconds)
    recorder.stop()
    guard done.wait(timeout: .now() + 20) != .timedOut else {
      FileHandle.standardError.write("ERROR: 收尾超时\n".data(using: .utf8)!)
      exit(1)
    }
    switch result {
    case .success(let url):
      print("MOV \(url.path)")
    case .failure(let error):
      FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
      exit(1)
    case nil:
      FileHandle.standardError.write("ERROR: 无结果\n".data(using: .utf8)!)
      exit(1)
    }
  }
}
