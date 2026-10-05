import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

// ScreenCaptureKit 只录到文件：SCStream 负责采集，SCRecordingOutput 负责写 .mov。
// 区域不是靠 content filter（filter 只支持 显示器/窗口/应用 粒度），
// 而是整屏采集 + SCStreamConfiguration.sourceRect 裁到选区。
final class Recorder: NSObject, SCRecordingOutputDelegate {
  enum RecorderError: LocalizedError {
    case noDisplay
    case queryContentFailed(Error)
    case startFailed(Error)
    case addOutputFailed(Error)
    case timeout

    var errorDescription: String? {
      switch self {
      case .noDisplay: return "取不到显示器列表"
      case .queryContentFailed(let e): return "查询可录内容失败：\(e.localizedDescription)"
      case .startFailed(let e): return "开始采集失败：\(e.localizedDescription)"
      case .addOutputFailed(let e): return "挂录制输出失败：\(e.localizedDescription)"
      case .timeout: return "启动录制超时"
      }
    }
  }

  private(set) var isRecording = false
  var onFinished: ((URL) -> Void)?
  var onFailed: ((Error) -> Void)?

  private var stream: SCStream?
  // 必须强引用：SCStream 不留 recording output，靠 autorelease pool 吊着的话，
  // app 的 run loop 一转就被释放，采集仍在系统进程里继续，但 delegate 再也收不到回调。
  private var recordingOutput: SCRecordingOutput?
  private var outURL: URL?

  // region 为 CG 坐标（点，左上原点）；nil = 整屏
  // excluding：要从画面里剔除的窗口（录制状态条等 UI），传 windowNumber
  //
  // async 版本：曾经用信号量在调用线程上同步等 SCShareableContent 查询和
  // startCapture，而调用方是 @MainActor 的 Model.start——查询期间整个 UI
  // 冻结、状态条渲染被推迟，还连锁推迟了对焦快照的 Task（要等主线程空出来），
  // Glass 提示音因此比实际开录晚约半秒。现在 await 让主线程立即返回。
  func start(region: CGRect?, to url: URL, excluding excludedWindowIDs: [Int] = []) async throws {
    let content: SCShareableContent
    do {
      // 首次运行时这个查询会挂着系统授权弹窗等用户决定：人在读弹窗、读选项，
      // 10 秒根本不够——而超时不是权限错误，needsPermission 不会置位，引导
      // 路径自己绊自己。所以查询放宽到 60 秒，10 秒只留给 startCapture。
      content = try await Self.withTimeout(seconds: 60) {
        try await SCShareableContent.current
      }
    } catch {
      throw RecorderError.queryContentFailed(error)
    }
    let displays = content.displays
    let allWindows = content.windows
    guard !displays.isEmpty else { throw RecorderError.noDisplay }

    // displays 的顺序不保证主屏在前；圈选 overlay 只出现在主屏，全屏也默认主屏。
    // CG 全局坐标的原点 (0,0) 恒为主屏左上角，据此认主屏。
    let display = (region.flatMap { r in
      displays.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }
    } ?? displays.first { $0.frame.origin == .zero }) ?? displays[0]

    // SCDisplay.width 报的是逻辑尺寸（HiDPI 屏上也是 1920 而非 3840），
    // 真实像素密度必须从当前显示模式取，否则 2x 屏按 1x 采样，成片发虚。
    let scale: CGFloat
    if let mode = CGDisplayCopyDisplayMode(display.displayID) {
      scale = CGFloat(mode.pixelWidth) / display.frame.width
    } else {
      scale = CGFloat(display.width) / display.frame.width
    }
    let src = region ?? display.frame
    // sourceRect 用的是所选显示器自己的逻辑坐标系（点，左上原点），
    // 不是 CG 全局坐标——副屏必须减去该屏原点的偏移。
    let srcRect = CGRect(
      x: src.minX - display.frame.minX,
      y: src.minY - display.frame.minY,
      width: src.width,
      height: src.height)
    dbg("display \(display.displayID) frame=\(display.frame) scale=\(scale) sourceRect=\(srcRect)")

    let config = SCStreamConfiguration()
    config.sourceRect = srcRect
    config.width = Int((srcRect.width * scale).rounded())
    config.height = Int((srcRect.height * scale).rounded())
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.capturesAudio = false
    // 按面板原生分辨率采集再缩放到 width/height；没有它 .auto 可能按 1x 采再放大
    config.captureResolution = .best

    // 全屏录制时状态条在画面内，必须从采集里剔除；
    // 框选时状态条在选区外本来就不入镜，剔除只是双保险。
    let excludedSC = allWindows.filter { sc in
      excludedWindowIDs.contains(Int(sc.windowID))
    }
    if excludedSC.count < excludedWindowIDs.count {
      dbg("warning: \(excludedWindowIDs.count - excludedSC.count) 个 overlay 窗口没匹配到 SCWindow，可能被录进成片")
    }
    let filter = SCContentFilter(display: display, excludingWindows: excludedSC)
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)

    let outputConfig = SCRecordingOutputConfiguration()
    outputConfig.outputURL = url
    outputConfig.outputFileType = .mov
    outputConfig.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: outputConfig, delegate: self)

    do {
      try stream.addRecordingOutput(output)
    } catch {
      throw RecorderError.addOutputFailed(error)
    }

    // startCapture 的回调若永远不来，不能让流程无限悬挂
    do {
      try await Self.withTimeout(seconds: 10) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          stream.startCapture { error in
            if let error { cont.resume(throwing: error) }
            else { cont.resume(returning: ()) }
          }
        }
      }
    } catch {
      throw RecorderError.startFailed(error)
    }

    self.stream = stream
    self.recordingOutput = output
    self.outURL = url
    isRecording = true
  }

  func stop() {
    guard let stream, isRecording else { return }
    isRecording = false
    stream.stopCapture { _ in }
  }

  // MARK: - 超时包装

  /// 带超时的 await：op 的结果或 .timeout，先到先得（resume-once 由锁保证）。
  /// 不用 task group 是因为它要求 ChildTaskResult: Sendable，系统类型未必满足。
  private static func withTimeout<T>(seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
    let once = TimeoutOnce()
    return try await withCheckedThrowingContinuation { cont in
      Task {
        do {
          let value = try await op()
          if once.claim() { cont.resume(returning: value) }
        } catch {
          if once.claim() { cont.resume(throwing: error) }
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if once.claim() { cont.resume(throwing: RecorderError.timeout) }
      }
    }
  }

  // MARK: SCRecordingOutputDelegate

  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    dbg("SCRecordingOutput didFinish")
    let url = outURL
    teardown()
    if let url { onFinished?(url) }
  }

  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    dbg("SCRecordingOutput didFail: \(error.localizedDescription)")
    isRecording = false
    teardown()
    onFailed?(error)
  }

  private func teardown() {
    stream = nil
    self.recordingOutput = nil
    outURL = nil
  }
}


/// withTimeout 的 resume-once 守卫：先到先得，后到者作废
private final class TimeoutOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
