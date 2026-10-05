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

    var errorDescription: String? {
      switch self {
      case .noDisplay: return "取不到显示器列表"
      case .queryContentFailed(let e): return "查询可录内容失败：\(e.localizedDescription)"
      case .startFailed(let e): return "开始采集失败：\(e.localizedDescription)"
      case .addOutputFailed(let e): return "挂录制输出失败：\(e.localizedDescription)"
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
  func start(region: CGRect?, to url: URL) throws {
    let sem = DispatchSemaphore(value: 0)
    var display: SCDisplay?
    var queryError: Error?
    Task {
      do {
        display = try await SCShareableContent.current.displays.first
      } catch {
        queryError = error
      }
      sem.signal()
    }
    sem.wait()
    if let queryError { throw RecorderError.queryContentFailed(queryError) }
    guard let display else { throw RecorderError.noDisplay }

    let scale = CGFloat(display.width) / display.frame.width
    let src = region ?? display.frame

    let config = SCStreamConfiguration()
    config.sourceRect = src
    config.width = Int((src.width * scale).rounded())
    config.height = Int((src.height * scale).rounded())
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.capturesAudio = false

    let filter = SCContentFilter(display: display, excludingWindows: [])
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

    let startSem = DispatchSemaphore(value: 0)
    var startError: Error?
    stream.startCapture { error in
      startError = error
      startSem.signal()
    }
    startSem.wait()
    if let startError { throw RecorderError.startFailed(startError) }

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
