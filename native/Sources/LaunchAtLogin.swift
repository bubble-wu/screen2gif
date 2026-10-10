import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

@MainActor
final class SystemLoginItemService: LoginItemService {
  var status: SMAppService.Status { SMAppService.mainApp.status }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLogin: ObservableObject {
  static let shared = LaunchAtLogin(service: SystemLoginItemService(), storage: UserDefaults.standard)
  static let initializedKey = "launchAtLoginInitialized"
  private let service: LoginItemService
  private let storage: PreferencesStorage

  @Published private(set) var status: SMAppService.Status
  @Published private(set) var errorMessage: String?

  init(service: LoginItemService, storage: PreferencesStorage) {
    self.service = service
    self.storage = storage
    status = service.status
  }

  /// Enable once on first launch. Later launches respect changes in System Settings.
  func start() {
    refresh()
    guard storage.object(forKey: Self.initializedKey) as? Bool != true else { return }
    storage.set(true, forKey: Self.initializedKey)
    if status == .notRegistered { setEnabled(true) }
  }

  var isEnabled: Bool { status == .enabled }
  var needsApproval: Bool { status == .requiresApproval }
  var detail: String {
    if let errorMessage { return errorMessage }
    switch status {
    case .enabled: return "登录 Mac 后自动启动，常驻菜单栏。"
    case .requiresApproval: return "尚未开启，请在系统设置的「登录项」中允许。"
    case .notFound: return "找不到应用的登录项，请重新打开完整应用后重试。"
    default: return "已关闭，可在需要时手动启动。"
    }
  }

  func refresh() {
    status = service.status
    if status == .enabled { errorMessage = nil }
  }

  func setEnabled(_ enabled: Bool) {
    storage.set(true, forKey: Self.initializedKey)
    errorMessage = nil
    do {
      if enabled {
        if service.status == .requiresApproval {
          refresh()
          return
        }
        if service.status != .enabled { try service.register() }
      } else if service.status != .notRegistered {
        try service.unregister()
      }
    } catch {
      errorMessage = "\(enabled ? "开启" : "关闭")失败：\(error.localizedDescription)"
    }
    status = service.status
  }

  func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
