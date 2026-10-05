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

  static func convert(mov: URL, regionPicked: Bool, completion: @escaping (Result<URL, Error>) -> Void) {
    let stampFormatter = DateFormatter()
    stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    let out = desktop.appendingPathComponent("screen2gif-\(stampFormatter.string(from: Date())).gif")

    let process = Process()
    process.executableURL = cliURL()
    // 圈选录制时用户已经框定取景，禁用 auto 裁剪，避免成片被裁到只剩运动区域
    process.arguments = ["convert", mov.path, "-o", out.path]
      + (regionPicked ? ["--crop", "off"] : [])
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
      // 字典序会把 v9 排在 v22 前面，按数字逐段比较、新版本优先
      dirs += versions
        .sorted(by: newestFirst)
        .map { nvm.appendingPathComponent("\($0)/bin").path }
    }
    dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    return dirs.joined(separator: ":")
  }

  private static func newestFirst(_ a: String, _ b: String) -> Bool {
    let x = versionNumbers(a)
    let y = versionNumbers(b)
    for i in 0..<max(x.count, y.count) {
      let l = i < x.count ? x[i] : 0
      let r = i < y.count ? y[i] : 0
      if l != r { return l > r }
    }
    return false
  }

  private static func versionNumbers(_ name: String) -> [Int] {
    name.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
  }
}
