import AppKit
import Foundation

// 转码复用现有 CLI 的关键帧/裁剪/调色板管线，app 只负责采集和交互。
enum Converter {
  static func cliURL() -> URL {
    // bundle: <proj>/native/build/screen2gif.app
    Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("bin/screen2gif")
  }

  static func convert(mov: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    let stampFormatter = DateFormatter()
    stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    let out = desktop.appendingPathComponent("screen2gif-\(stampFormatter.string(from: Date())).gif")

    let process = Process()
    process.executableURL = cliURL()
    process.arguments = ["convert", mov.path, "-o", out.path]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchPATH()
    process.environment = env
    process.terminationHandler = { proc in
      if proc.terminationStatus == 0 {
        completion(.success(out))
      } else {
        completion(.failure(NSError(
          domain: "screen2gif", code: Int(proc.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: "转码失败（exit \(proc.terminationStatus)）"])))
      }
    }
    do {
      try process.run()
    } catch {
      completion(.failure(error))
    }
  }

  // GUI app 继承的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
  // CLI 的 shebang（env node）和它要调的 ffmpeg 都不在里面，必须自己拼。
  static func searchPATH() -> String {
    var dirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let nvm = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nvm/versions/node")
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
      dirs += versions.sorted().reversed().map { nvm.appendingPathComponent("\($0)/bin").path }
    }
    dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    return dirs.joined(separator: ":")
  }
}
