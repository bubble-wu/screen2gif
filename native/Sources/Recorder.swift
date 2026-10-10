import AppKit
import AVFoundation
import ScreenCaptureKit

/// All session state belongs to the main actor; SDK callbacks only enqueue work.
@MainActor
final class Recorder: NSObject, SCRecordingOutputDelegate {
  enum RecorderError: LocalizedError {
    case noDisplay
    case queryContentFailed(Error)
    case startFailed(Error)
    case addOutputFailed(Error)

    var errorDescription: String? {
      switch self {
      case .noDisplay: return "取不到显示器列表，请检查屏幕录制权限"
      case .queryContentFailed(let e): return "查询可录内容失败：\(e.localizedDescription)"
      case .startFailed(let e): return "开始采集失败：\(e.localizedDescription)"
      case .addOutputFailed(let e): return "挂录制输出失败：\(e.localizedDescription)"
      }
    }
  }

  @MainActor
  private final class Run {
    let id: UUID
    let url: URL
    let started = CaptureResult<Void>()
    var stream: SCStream?
    var output: SCRecordingOutput?
    var stopping = false
    init(id: UUID, url: URL) { self.id = id; self.url = url }
  }

  private var lifecycle = RecordingLifecycle()
  private var current: Run?
  // Keep abandoned streams alive during bounded, best-effort cleanup.
  private var retiring: [UUID: Run] = [:]
  var isRecording: Bool { lifecycle.isRecording }
  var onFinished: ((URL) -> Void)?
  var onFailed: ((Error) -> Void)?

  func start(region: CGRect?, to url: URL, excluding excludedWindowIDs: [Int] = []) async throws {
    abort()
    let run = Run(id: lifecycle.begin(), url: url)
    current = run
    do {
      let content: SCShareableContent
      do {
        content = try await captureWithDeadline(seconds: 60) { try await SCShareableContent.current }
      } catch { throw RecorderError.queryContentFailed(error) }
      try requireCurrent(run)
      guard !content.displays.isEmpty else { throw RecorderError.noDisplay }
      let display = (region.flatMap { r in
        content.displays.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }
      } ?? content.displays.first { $0.frame.origin == .zero }) ?? content.displays[0]
      let scale = CGDisplayCopyDisplayMode(display.displayID).map {
        CGFloat($0.pixelWidth) / display.frame.width
      } ?? CGFloat(display.width) / display.frame.width
      let src = (region ?? display.frame).intersection(display.frame)
      guard src.width >= 8, src.height >= 8 else { throw RecorderError.noDisplay }
      let config = SCStreamConfiguration()
      config.sourceRect = CGRect(x: src.minX - display.frame.minX, y: src.minY - display.frame.minY,
                                 width: src.width, height: src.height)
      config.width = max(2, Int((src.width * scale).rounded()) / 2 * 2)
      config.height = max(2, Int((src.height * scale).rounded()) / 2 * 2)
      config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
      config.capturesAudio = false
      config.captureResolution = .best
      let excluded = content.windows.filter { excludedWindowIDs.contains(Int($0.windowID)) }
      // Exclude this app as well, so a just-created overlay missing from the
      // window snapshot can never leak into the recording.
      let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
      let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
      let windowFilter = SCContentFilter(display: display, excludingWindows: excluded)
      let stream = SCStream(filter: ownApp.isEmpty ? windowFilter : filter, configuration: config, delegate: nil)
      let outputConfig = SCRecordingOutputConfiguration()
      outputConfig.outputURL = url
      outputConfig.outputFileType = .mov
      outputConfig.videoCodecType = .h264
      let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
      run.stream = stream
      run.output = output
      do { try stream.addRecordingOutput(output) }
      catch { throw RecorderError.addOutputFailed(error) }

      try await captureWithDeadline(seconds: 10) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          stream.startCapture { [weak self] error in
            Task { @MainActor in
              // A successful start may arrive after cancel/timeout and cleanup.
              // Stop that old stream again; it must never revive the UI.
              if self?.lifecycle.accepts(run.id) != true, let lateStream = run.stream {
                Task { @MainActor in
                  _ = try? await captureWithDeadline(seconds: 5) { try await lateStream.stopCapture() }
                }
              }
              if let error { cont.resume(throwing: error) }
              else { cont.resume(returning: ()) }
            }
          }
        }
        // startCapture alone does not prove the file writer is recording.
        try await run.started.value()
      }
      try requireCurrent(run)
      lifecycle.started(run.id)
    } catch {
      if lifecycle.accepts(run.id) { abort() }
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw RecorderError.startFailed(error)
    }
  }

  private func requireCurrent(_ run: Run) throws {
    try Task.checkCancellation()
    guard lifecycle.accepts(run.id) else { throw CancellationError() }
  }

  func stop() {
    guard let run = current, lifecycle.isRecording, !run.stopping else { return }
    run.stopping = true
    run.stream?.stopCapture { [weak self] error in
      guard let error else { return }
      Task { @MainActor in
        guard let self, self.lifecycle.accepts(run.id) else { return }
        self.abort()
        self.onFailed?(error)
      }
    }
  }

  /// Invalidate first, then clean up without blocking error reporting or retry.
  func abort() {
    guard let run = current else { return }
    lifecycle.finish(run.id)
    current = nil
    run.started.resolve(.failure(CancellationError()))
    guard let stream = run.stream else { return }
    retiring[run.id] = run
    Task { @MainActor [weak self] in
      _ = try? await captureWithDeadline(seconds: 5) { try await stream.stopCapture() }
      self?.retiring.removeValue(forKey: run.id)
    }
  }

  private func activeRun(for output: SCRecordingOutput) -> Run? {
    guard let run = current, run.output === output, lifecycle.accepts(run.id) else { return nil }
    return run
  }

  nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in
      self.activeRun(for: recordingOutput)?.started.resolve(.success(()))
    }
  }

  nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in
      guard let run = self.activeRun(for: recordingOutput) else { return }
      // An early finish during startup cannot promote a completed run to REC.
      run.started.resolve(.failure(CancellationError()))
      let wasRecording = self.lifecycle.isRecording
      self.lifecycle.finish(run.id)
      self.current = nil
      if wasRecording { self.onFinished?(run.url) }
      else { self.onFailed?(RecorderError.startFailed(CancellationError())) }
    }
  }

  nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    Task { @MainActor in
      guard let run = self.activeRun(for: recordingOutput) else { return }
      run.started.resolve(.failure(error))
      let wasRecording = self.lifecycle.isRecording
      self.abort()
      // The waiting start() reports startup failures; avoid a second UI callback.
      if wasRecording { self.onFailed?(error) }
    }
  }
}
