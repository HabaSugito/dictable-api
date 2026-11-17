import AppKit
import Foundation
import HarkCore
import Observation
import ServiceManagement

struct Activity: Identifiable {
  enum Kind { case stream, file, request, info, error }
  let id = UUID()
  let date = Date()
  let kind: Kind
  let text: String
}

/// App state shown in the menu bar window. All mutations happen on the main actor.
@MainActor
@Observable
final class ServerModel {
  enum Status: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
  }

  private(set) var status: Status = .stopped
  private(set) var activeStreams: Set<UUID> = []
  private(set) var streamLocales: [UUID: String] = [:]
  private(set) var transcriptCount = 0
  private(set) var requestCount = 0
  private(set) var activity: [Activity] = []
  private(set) var installedLocales: [String] = []
  private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

  var portText: String
  /// Validation message for the port field.
  private(set) var portError: String?
  /// A free port offered when the configured one is taken.
  private(set) var suggestedPort: UInt16?
  private(set) var loginItemError: String?

  private var server: HarkServer?
  private var generation = UUID()
  private static let portKey = "port"
  static let defaultPort: UInt16 = 8082

  var port: UInt16 {
    let stored = UserDefaults.standard.integer(forKey: Self.portKey)
    return stored > 0 && stored <= 65535 ? UInt16(stored) : Self.defaultPort
  }

  var httpURL: String { "http://127.0.0.1:\(port)" }
  var wsURL: String { "ws://127.0.0.1:\(port)/v1/stream" }
  var isRunning: Bool { status == .running }

  init() {
    portText = ""
    portText = String(port)
    start()
    Task { await refreshLocales() }
  }

  func start() {
    stop()
    portError = nil
    // Check first, so a clash with another app gets a clear message and a free alternative.
    guard PortProbe.isAvailable(port) else {
      suggestedPort = PortProbe.firstAvailable(after: port)
      status = .failed("Port \(port) is already used by another app.")
      log(.error, "Port \(port) is already in use")
      return
    }
    suggestedPort = nil
    status = .starting
    // Events from a previous server (e.g. its late "stopped") must not overwrite the new state.
    let generation = UUID()
    self.generation = generation
    let server = HarkServer(port: port) { [weak self] event in
      Task { @MainActor in
        guard let self, self.generation == generation else { return }
        self.handle(event)
      }
    }
    do {
      try server.start()
      self.server = server
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    generation = UUID()  // ignore anything the old server still reports
    server?.stop()
    server = nil
    activeStreams.removeAll()
    streamLocales.removeAll()
    status = .stopped
  }

  func toggle() {
    isRunning ? stop() : start()
  }

  /// Saves the port typed in the port field and restarts the server.
  func applyPort() {
    guard let value = PortProbe.parse(portText) else {
      portError = "Enter a number between 1024 and 65535."
      return
    }
    // The current port is "in use" by Hark itself, so only check other ports.
    if value != port || !isRunning {
      guard PortProbe.isAvailable(value) || (value == port && isRunning) else {
        portError = "Port \(value) is in use. Try \(PortProbe.firstAvailable(after: value).map(String.init) ?? "another port")."
        return
      }
    }
    usePort(value)
  }

  /// Switches to `value`, saves it, and restarts the server.
  func usePort(_ value: UInt16) {
    UserDefaults.standard.set(Int(value), forKey: Self.portKey)
    portText = String(value)
    portError = nil
    log(.info, "Port changed to \(value). Update your clients (e.g. the Chrome extension) to the new URL.")
    start()
  }

  func resetPortText() {
    portText = String(port)
    portError = nil
  }

  /// Registers/unregisters the app as a login item (System Settings → General → Login Items).
  func setLaunchAtLogin(_ enabled: Bool) {
    loginItemError = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      loginItemError = "Could not change the login item: \(error.localizedDescription)"
    }
    let status = SMAppService.mainApp.status
    launchAtLogin = status == .enabled
    if enabled && status == .requiresApproval {
      loginItemError = "Allow Hark Server in System Settings → General → Login Items."
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }

  func refreshLocales() async {
    installedLocales = await SpeechLocales.installed()
  }

  private func handle(_ event: ServerEvent) {
    switch event {
    case .started(let port):
      status = .running
      log(.info, "Listening on 127.0.0.1:\(port)")
    case .waitingForPort(let port):
      status = .starting
      log(.info, "Port \(port) was just released by another app. Waiting for macOS to free it…")
    case .stopped:
      if case .failed = status { return }
      status = .stopped
    case .failed(let message):
      status = .failed(message)
      log(.error, message)
    case .streamOpened(let id, let client):
      activeStreams.insert(id)
      log(.stream, "Stream opened · \(Self.shortClient(client))")
    case .streamReady(let id, let locale):
      streamLocales[id] = locale
    case .streamClosed(let id):
      activeStreams.remove(id)
      streamLocales[id] = nil
    case .modelDownloading(let locale):
      log(.info, "Downloading speech model for \(locale)…")
      Task { await refreshLocales() }
    case .transcript(let source, _, let text):
      transcriptCount += 1
      log(source == .file ? .file : .stream, text)
    case .request(let method, let path, let status):
      requestCount += 1
      if status >= 400 { log(.error, "\(method) \(path) → \(status)") }
    }
  }

  private func log(_ kind: Activity.Kind, _ text: String) {
    activity.insert(Activity(kind: kind, text: text), at: 0)
    if activity.count > 30 { activity.removeLast(activity.count - 30) }
  }

  private static func shortClient(_ client: String) -> String {
    if client.hasPrefix("chrome-extension://") { return "Chrome extension" }
    return String(client.prefix(40))
  }
}
