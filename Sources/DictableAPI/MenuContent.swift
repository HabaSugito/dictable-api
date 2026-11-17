import DictableCore
import SwiftUI

struct MenuContent: View {
  @Bindable var model: ServerModel
  @State private var showSettings = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if case .failed(let message) = model.status { failure(message) }
      if model.isRunning { endpoints }
      stats
      Divider()
      activityList
      Divider()
      if showSettings { settings }
      footer
    }
    .padding(14)
    .frame(width: 340)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "waveform")
        .font(.title2)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Dictable API").font(.headline)
        HStack(spacing: 5) {
          Circle().fill(statusColor).frame(width: 7, height: 7)
          Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Toggle(
        "Server",
        isOn: Binding(get: { model.isRunning || model.status == .starting }, set: { _ in model.toggle() })
      )
      .toggleStyle(.switch)
      .labelsHidden()
      .controlSize(.small)
    }
  }

  private var endpoints: some View {
    VStack(spacing: 6) {
      EndpointRow(label: "HTTP", value: model.httpURL + "/v1", copy: model.copy)
      EndpointRow(label: "WS", value: model.wsURL, copy: model.copy)
    }
  }

  private func failure(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if let suggested = model.suggestedPort {
          Button("Use port \(String(suggested)) instead") { model.usePort(suggested) }
            .buttonStyle(.borderedProminent)
        }
        Button("Choose a port…") { showSettings = true }
      }
      .controlSize(.small)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private var stats: some View {
    HStack(spacing: 0) {
      Stat(value: "\(model.activeStreams.count)", label: "live streams")
      Stat(value: "\(model.transcriptCount)", label: "transcripts")
      Stat(value: "\(model.requestCount)", label: "requests")
    }
  }

  private var activityList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recent activity").font(.caption).foregroundStyle(.secondary)
      if model.activity.isEmpty {
        Text("Nothing yet. Point an OpenAI SDK or a WebSocket client at the endpoints above.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(model.activity.prefix(12)) { item in
              ActivityRow(item: item)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Settings").font(.subheadline.weight(.semibold))

      // Port: other local servers can use the same number, so it can be changed here.
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text("Port")
          TextField("8082", text: $model.portText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .multilineTextAlignment(.trailing)
            .onSubmit { model.applyPort() }
          if model.portText != String(model.port) {
            Button("Apply") { model.applyPort() }
              .keyboardShortcut(.defaultAction)
            Button("Cancel") { model.resetPortText() }
          }
          Spacer()
        }
        .controlSize(.small)
        if let error = model.portError {
          Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Clients must use the same port (e.g. the Chrome extension's server URL).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      // Launch at login
      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          "Start automatically when I log in",
          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
        )
        .toggleStyle(.checkbox)
        if let error = model.loginItemError {
          Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
      }

      // Not a setting, but useful context next to them.
      VStack(alignment: .leading, spacing: 2) {
        Text("Downloaded languages").font(.caption).foregroundStyle(.secondary)
        Text(
          model.installedLocales.isEmpty
            ? "None yet. macOS downloads a language the first time it is used."
            : model.installedLocales.joined(separator: ", ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
    }
    .task { await model.refreshLocales() }
  }

  private var footer: some View {
    HStack {
      Button(showSettings ? "Hide settings" : "Settings…") { showSettings.toggle() }
      Spacer()
      Text("v\(appVersion)").font(.caption2).foregroundStyle(.tertiary)
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .buttonStyle(.borderless)
    .font(.callout)
  }

  private var statusText: String {
    switch model.status {
    case .running: model.activeStreams.isEmpty ? "Running on port \(model.port)" : "Transcribing live"
    case .starting: "Starting…"
    case .stopped: "Stopped"
    case .failed: "Error"
    }
  }

  private var statusColor: Color {
    switch model.status {
    case .running: .green
    case .starting: .yellow
    case .stopped: .gray
    case .failed: .red
    }
  }
}

private struct EndpointRow: View {
  let label: String
  let value: String
  let copy: (String) -> Void
  @State private var copied = false

  var body: some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 30, alignment: .leading)
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer(minLength: 4)
      Button {
        copy(value)
        copied = true
        Task {
          try? await Task.sleep(for: .seconds(1.2))
          copied = false
        }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help("Copy")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
  }
}

private struct Stat: View {
  let value: String
  let label: String

  var body: some View {
    VStack(spacing: 2) {
      Text(value).font(.title3.monospacedDigit().weight(.semibold))
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct ActivityRow: View {
  let item: Activity

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(color)
        .frame(width: 12)
      Text(item.text)
        .font(.caption)
        .lineLimit(2)
        .foregroundStyle(item.kind == .error ? .red : .primary)
      Spacer(minLength: 0)
      Text(item.date, style: .time)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var icon: String {
    switch item.kind {
    case .stream: "dot.radiowaves.left.and.right"
    case .file: "doc.text"
    case .request: "arrow.left.arrow.right"
    case .info: "info.circle"
    case .error: "exclamationmark.circle"
    }
  }

  private var color: Color {
    switch item.kind {
    case .stream: .blue
    case .file: .purple
    case .request, .info: .secondary
    case .error: .red
    }
  }
}
