import SwiftUI

// GUI 启动时 stderr 落到 /dev/null；从终端直接跑 app 二进制就能看到，用于调试。
func dbg(_ message: String) {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

@MainActor
final class Model: ObservableObject {
  enum Phase { case idle, picking, recording, converting }

  @Published var phase: Phase = .idle
  @Published var statusLine = ""
  @Published var needsPermission = false

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
  }

  func startFullscreen() { start(region: nil) }

  func startRegion() {
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
    do {
      try recorder.start(region: region, to: mov)
      regionPicked = (region != nil)
      phase = .recording
      statusLine = ""
      needsPermission = false
      RecordingOverlay.show(region: region)
      Self.cue("Glass")
    } catch {
      fail(error)
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

  var body: some View {
    switch model.phase {
    case .idle:
      Text(model.statusLine.isEmpty ? "screen2gif" : model.statusLine)
      if model.needsPermission {
        Button("打开屏幕录制设置…") { model.openScreenCaptureSettings() }
      }
      Divider()
      Button("录制全屏") { model.startFullscreen() }
      Button("框选区域录制…") { model.startRegion() }
      Divider()
      Button("退出") { NSApplication.shared.terminate(nil) }
    case .picking:
      Text("在屏幕上拖拽框选…（Esc 取消）")
    case .recording:
      Text("● 录制中")
      Button("停止录制并转码") { model.stop() }
    case .converting:
      Text(model.statusLine)
    }
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
    do {
      try recorder.start(region: region, to: mov)
    } catch {
      FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
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
