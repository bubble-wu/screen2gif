import AppKit
import Foundation

// 转码复用现有 CLI 的关键帧/裁剪/调色板管线，app 只负责采集和交互。
enum Converter {
  static func cliURL() -> URL {
    Bundle.main.resourceURL!
      .appendingPathComponent("cli/bin/screen2gif")
  }

  static func convert(mov: URL, regionPicked: Bool, settings: ExportSettings, completion: @escaping (Result<URL, Error>) -> Void) {
    let stampFormatter = DateFormatter()
    stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
    let out = settings.directory
      .appendingPathComponent("screen2gif-\(stampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).gif")

    // The build embeds the full CLI; a missing file means an incomplete bundle.
    let cli = cliURL()
    guard FileManager.default.isExecutableFile(atPath: cli.path) else {
      completion(.failure(NSError(
        domain: "screen2gif", code: 2,
        userInfo: [NSLocalizedDescriptionKey:
          "找不到转码 CLI：\(cli.path)。应用资源不完整，请重新运行 native/build.sh"])))
      return
    }

    let watermarkURL: URL?
    do {
      if let text = settings.effectiveWatermarkText {
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("s2g-watermark-\(UUID().uuidString).png")
        try TextWatermark.png(text).write(to: url, options: .atomic)
        watermarkURL = url
      } else { watermarkURL = nil }
    } catch {
      completion(.failure(error))
      return
    }

    let process = Process()
    process.executableURL = cli
    // 圈选录制时用户已经框定取景，禁用 auto 裁剪，避免成片被裁到只剩运动区域
    process.arguments = settings.arguments(input: mov, output: out, regionPicked: regionPicked)
    if let watermarkURL { process.arguments! += ["--watermark-overlay", watermarkURL.path] }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchPATH()
    process.environment = env
    // CLI 的具体诊断（node/ffmpeg 缺失、编码失败…）都写在 stderr，
    // 只透出 exit code 的话用户永远看不到真实原因。
    // stderr 量很小（< 64KB 管道缓冲），进程退出后一次读完即可，无死锁风险。
    let errPipe = Pipe()
    process.standardError = errPipe
    // 看门狗：CLI/ffmpeg 卡死时强杀并走失败路径，GUI 不至于永远停在「转码中…」
    let watchdog = DispatchWorkItem {
      if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: watchdog)
    process.terminationHandler = { proc in
      watchdog.cancel()
      if let watermarkURL { try? FileManager.default.removeItem(at: watermarkURL) }
      let errText = String(
        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
      let lastLine = errText
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last(where: { !$0.isEmpty })
      if proc.terminationStatus == 0 {
        completion(.success(out))
      } else {
        let detail = lastLine.map { "：\($0)" } ?? ""
        completion(.failure(NSError(
          domain: "screen2gif", code: Int(proc.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey:
            "转码失败（exit \(proc.terminationStatus)）\(detail)"])))
      }
    }
    do {
      try process.run()
    } catch {
      watchdog.cancel()
      if let watermarkURL { try? FileManager.default.removeItem(at: watermarkURL) }
      completion(.failure(error))
    }
  }

  // GUI app 继承的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
  // CLI 的 shebang（env node）和它要调的 ffmpeg 都不在里面，必须自己拼。
  // 覆盖常见 node 版本管理器：nvm / fnm / volta / asdf。
  static func searchPATH() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var dirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let nvm = home.appendingPathComponent(".nvm/versions/node")
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
      // 字典序会把 v9 排在 v22 前面，按数字逐段比较、新版本优先
      dirs += versions
        .sorted(by: newestFirst)
        .map { nvm.appendingPathComponent("\($0)/bin").path }
    }
    let fnm = home.appendingPathComponent(".local/share/fnm/node-versions")
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnm.path) {
      dirs += versions
        .sorted(by: newestFirst)
        .map { fnm.appendingPathComponent("\($0)/installation/bin").path }
    }
    dirs += [
      home.appendingPathComponent(".volta/bin").path,
      home.appendingPathComponent(".asdf/shims").path,
    ]
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


// 依赖就位检查 + Homebrew 一键安装：GUI 侧对应 CLI 的 lib/deps.mjs。
// 启动时查一次，缺了直接在菜单里给「安装缺失依赖」按钮，
// 用户不用知道 ffmpeg/node/brew 是什么。
enum Deps {
  /// 缺失的依赖名（node / ffmpeg / ffprobe）
  static func missing() -> [String] {
    let dirs = Converter.searchPATH().split(separator: ":").map(String.init)
    func find(_ name: String) -> Bool {
      dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }
    var result: [String] = []
    if !find("node") { result.append("node") }
    if !find("ffmpeg") { result.append("ffmpeg") }
    if !find("ffprobe") { result.append("ffprobe") }
    return result
  }

  static var brewURL: URL? {
    for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
      if FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
      }
    }
    return nil
  }
}
