import SwiftUI

@main
struct HarkServerApp: App {
  @State private var model = ServerModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      Image(systemName: menuIcon)
        .accessibilityLabel("Hark Server")
    }
    .menuBarExtraStyle(.window)
  }

  private var menuIcon: String {
    switch model.status {
    case .running: model.activeStreams.isEmpty ? "waveform" : "waveform.badge.mic"
    case .starting: "waveform"
    case .stopped: "waveform.slash"
    case .failed: "exclamationmark.triangle"
    }
  }
}
