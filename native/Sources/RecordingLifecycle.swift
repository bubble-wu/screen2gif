import Foundation

/// Every async completion must carry the session that created it.
struct RecordingLifecycle {
  private(set) var id: UUID?
  private(set) var isRecording = false

  mutating func begin() -> UUID {
    let next = UUID()
    id = next
    isRecording = false
    return next
  }

  func accepts(_ candidate: UUID) -> Bool { id == candidate }

  @discardableResult
  mutating func started(_ candidate: UUID) -> Bool {
    guard accepts(candidate) else { return false }
    isRecording = true
    return true
  }

  @discardableResult
  mutating func finish(_ candidate: UUID) -> Bool {
    guard accepts(candidate) else { return false }
    id = nil
    isRecording = false
    return true
  }
}

enum CaptureDeadlineError: LocalizedError {
  case timeout
  var errorDescription: String? { "录制操作超时" }
}

/// A single result shared by the delegate, timeout and cancellation paths.
final class CaptureResult<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?
  private var continuation: CheckedContinuation<Value, Error>?

  func resolve(_ value: Result<Value, Error>) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    result = value
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume(with: value)
  }

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { cont in
      lock.lock()
      if let result {
        lock.unlock()
        cont.resume(with: result)
      } else {
        continuation = cont
        lock.unlock()
      }
    }
  }
}

/// Unlike a task group, returning on timeout does not await an unresponsive API.
@MainActor
func captureWithDeadline<Value>(seconds: Double, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
  let result = CaptureResult<Value>()
  let worker = Task { @MainActor in
    do { result.resolve(.success(try await operation())) }
    catch { result.resolve(.failure(error)) }
  }
  let timer = Task { @MainActor in
    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    catch { return }
    result.resolve(.failure(CaptureDeadlineError.timeout))
  }
  defer { timer.cancel(); worker.cancel() }
  return try await withTaskCancellationHandler {
    try await result.value()
  } onCancel: {
    result.resolve(.failure(CancellationError()))
  }
}
