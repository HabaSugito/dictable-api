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

  private var server: HarkServer?
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
    status = .starting
    let server = HarkServer(port: port) { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    do {
      try server.start()
      self.server = server
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func stop() {
    server?.stop()
    server = nil
    activeStreams.removeAll()
    streamLocales.removeAll()
    status = .stopped
  }

  func toggle() {
    isRunning ? stop() : start()
  }

  /// Saves the port typed in the settings field and restarts the server.
  func applyPort() {
    guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value >= 1024 else {
      portText = String(port)
      log(.error, "Port must be a number between 1024 and 65535.")
      return
    }
    UserDefaults.standard.set(Int(value), forKey: Self.portKey)
    start()
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      log(.error, "Launch at login: \(error.localizedDescription)")
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
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
