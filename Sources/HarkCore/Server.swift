import Foundation
@preconcurrency import Network

public let harkVersion = "1.1.0"

/// Seconds rounded to milliseconds, so JSON shows 21.54 rather than 21.539999999999999.
func roundMs(_ seconds: Double) -> Double {
  guard seconds.isFinite else { return 0 }
  return (seconds * 1000).rounded() / 1000
}

public enum ServerEvent: Sendable {
  public enum Source: String, Sendable {
    case stream
    case file
  }

  case started(port: UInt16)
  /// The port was just released by another program; the server retries until macOS frees it (≤ ~30 s).
  case waitingForPort(port: UInt16)
  case stopped
  case failed(String)
  case streamOpened(id: UUID, client: String)
  case streamReady(id: UUID, locale: String)
  case streamClosed(id: UUID)
  case modelDownloading(locale: String)
  case transcript(source: Source, locale: String, text: String)
  case request(method: String, path: String, status: Int)
}

/// HTTP + WebSocket server on 127.0.0.1, built directly on Network.framework (no dependencies).
///
/// - `POST /v1/audio/transcriptions` — OpenAI-compatible file transcription
/// - `GET  /v1/models`, `/v1/locales`, `/health`
/// - `ws://…/v1/stream` (or `/`) — live transcription with partial results
public final class HarkServer: @unchecked Sendable {
  public let port: UInt16
  let onEvent: @Sendable (ServerEvent) -> Void
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: ClientConnection] = [:]
  private let lock = NSLock()

  public init(port: UInt16, onEvent: @escaping @Sendable (ServerEvent) -> Void) {
    self.port = port
    self.onEvent = onEvent
  }

  private let listenerQueue = DispatchQueue(label: "hark.listener")
  private var stopped = false
  private var bindAttempts = 0
  /// macOS keeps a just-closed port in TIME_WAIT for up to ~30 s; retry for a bit longer than that.
  static let maxBindAttempts = 25
  static let bindRetryDelay: TimeInterval = 1.5

  public func start() throws {
    guard NWEndpoint.Port(rawValue: port) != nil else { throw HTTPError.malformed("invalid port") }
    stopped = false
    bindAttempts = 0
    try startListener()
  }

  private func startListener() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      let client = ClientConnection(connection: connection, server: self)
      self.lock.withLock { self.connections[ObjectIdentifier(client)] = client }
      client.start()
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.onEvent(.started(port: self.port))
      case .failed(let error):
        listener?.cancel()
        self.handleFailure(error)
      case .cancelled:
        if self.stopped { self.onEvent(.stopped) }
      default:
        break
      }
    }
    lock.withLock { self.listener = listener }
    listener.start(queue: listenerQueue)
  }

  /// "Address in use" while no one is actually listening means the port was just released and still has
  /// connections in TIME_WAIT. Network.framework refuses to bind then, so wait and try again.
  private func handleFailure(_ error: NWError) {
    let inUse: Bool
    if case .posix(let code) = error, code == .EADDRINUSE { inUse = true } else { inUse = false }
    if inUse, !stopped, bindAttempts < Self.maxBindAttempts, PortProbe.isAvailable(port) {
      bindAttempts += 1
      if bindAttempts == 1 { onEvent(.waitingForPort(port: port)) }
      listenerQueue.asyncAfter(deadline: .now() + Self.bindRetryDelay) { [weak self] in
        guard let self, !self.stopped else { return }
        do {
          try self.startListener()
        } catch {
          self.onEvent(.failed(error.localizedDescription))
        }
      }
      return
    }
    onEvent(.failed(Self.describe(error, port: port)))
  }

  public func stop() {
    stopped = true
    let listener = lock.withLock { () -> NWListener? in
      defer { self.listener = nil }
      return self.listener
    }
    listener?.cancel()
    if listener == nil { onEvent(.stopped) }
    let clients = lock.withLock { Array(connections.values) }
    clients.forEach { $0.close() }
  }

  func remove(_ client: ClientConnection) {
    _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(client)) }
  }

  static func describe(_ error: NWError, port: UInt16) -> String {
    if case .posix(let code) = error, code == .EADDRINUSE {
      return "Port \(port) is already in use."
    }
    return error.localizedDescription
  }

  // MARK: - HTTP routing

  func handle(_ request: HTTPRequest) async -> HTTPResponse {
    switch (request.method, request.path) {
    case ("GET", "/health"), ("GET", "/"):
      return .json(["status": "ok", "server": "hark", "version": harkVersion])

    case ("GET", "/v1/models"):
      return .json([
        "object": "list",
        "data": [["id": "apple-on-device", "object": "model", "owned_by": "system", "created": 0]],
      ])

    case ("GET", "/v1/locales"):
      return .json(["supported": await SpeechLocales.supported(), "installed": await SpeechLocales.installed()])

    case ("POST", "/v1/audio/transcriptions"):
      return await transcribeFile(request)

    case (_, "/v1/audio/transcriptions"), (_, "/v1/models"), (_, "/v1/locales"), (_, "/health"):
      return .error("Method \(request.method) is not allowed.", status: 405)

    default:
      return .error("No route for \(request.method) \(request.path).", status: 404)
    }
  }

  func transcribeFile(_ request: HTTPRequest) async -> HTTPResponse {
    guard let boundary = Multipart.boundary(from: request.header("content-type")) else {
      return .error("Send the audio as multipart/form-data with a 'file' field.", status: 415)
    }
    let parts: [Multipart.Part]
    do {
      parts = try Multipart.parse(request.body, boundary: boundary)
    } catch {
      return .error("Could not parse the multipart body.", status: 400)
    }
    let fields = Dictionary(parts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    guard let file = fields["file"], !file.data.isEmpty else {
      return .error("Missing required field 'file'.", status: 400)
    }
    let formatName = fields["response_format"]?.stringValue ?? "json"
    guard let format = ResponseFormat(rawValue: formatName) else {
      let options = ResponseFormat.allCases.map(\.rawValue).joined(separator: ", ")
      return .error("Unsupported response_format '\(formatName)'. Use one of: \(options).", status: 400)
    }

    let ext = (file.filename as NSString?)?.pathExtension ?? ""
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("hark-\(UUID().uuidString)")
      .appendingPathExtension(ext.isEmpty ? "wav" : ext)
    defer { try? FileManager.default.removeItem(at: url) }

    do {
      try file.data.write(to: url)
      let result = try await FileTranscriber.transcribe(fileURL: url, locale: fields["language"]?.stringValue)
      onEvent(.transcript(source: .file, locale: result.locale, text: result.text))
      switch format {
      case .json:
        return .json(["text": result.text])
      case .text:
        return .text(result.text)
      case .verboseJSON:
        return .json([
          "task": "transcribe",
          "language": result.locale,
          "duration": roundMs(result.duration),
          "text": result.text,
          "segments": result.segments.enumerated().map { i, s in
            ["id": i, "start": roundMs(s.start), "end": roundMs(s.end), "text": s.text] as [String: Any]
          },
        ])
      case .srt:
        return .text(ResponseFormat.srt(result.segments), contentType: "application/x-subrip; charset=utf-8")
      case .vtt:
        return .text(ResponseFormat.vtt(result.segments), contentType: "text/vtt; charset=utf-8")
      }
    } catch let error as SpeechEngineError {
      return .error(error.localizedDescription, status: 422)
    } catch {
      return .error(error.localizedDescription, status: 500, type: "server_error")
    }
  }
}

/// One TCP connection: speaks HTTP/1.1 until it is upgraded to a WebSocket.
final class ClientConnection: @unchecked Sendable {
  let connection: NWConnection
  weak var server: HarkServer?
  let queue = DispatchQueue(label: "hark.connection")
  let id = UUID()
  private var buffer = Data()
  private var isWebSocket = false
  private var isHandling = false
  private var closed = false
  private var assembler = WebSocketMessageAssembler()
  private var transcriber: StreamTranscriber?

  init(connection: NWConnection, server: HarkServer) {
    self.connection = connection
    self.server = server
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.close()
      default: break
      }
    }
    connection.start(queue: queue)
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.buffer.append(data)
        self.process()
      }
      if isComplete || error != nil {
        self.close()
        return
      }
      self.receive()
    }
  }

  // Runs on `queue`.
  private func process() {
    if isWebSocket {
      processFrames()
      return
    }
    guard !isHandling else { return }
    do {
      guard let (request, used) = try HTTPParser.parse(buffer) else { return }
      buffer.removeFirst(used)
      isHandling = true
      route(request)
    } catch HTTPError.payloadTooLarge {
      respond(.error("The upload is too large.", status: 413), method: "?", path: "?")
    } catch {
      respond(.error("Malformed HTTP request.", status: 400), method: "?", path: "?")
    }
  }

  private func route(_ request: HTTPRequest) {
    guard AccessPolicy.isAllowedHost(request.header("host")) else {
      respond(.error("Host not allowed.", status: 403, type: "forbidden"), method: request.method, path: request.path)
      return
    }
    let origin = request.header("origin")
    guard AccessPolicy.isAllowedOrigin(origin) else {
      respond(.error("Origin \(origin ?? "") is not allowed.", status: 403, type: "forbidden"), method: request.method, path: request.path)
      return
    }
    if request.isWebSocketUpgrade {
      upgrade(request)
      return
    }
    if request.method == "OPTIONS" {
      respond(HTTPResponse(status: 204), origin: origin, method: request.method, path: request.path)
      return
    }
    Task {
      let response = await server?.handle(request) ?? .error("Server stopped.", status: 503)
      queue.async { self.respond(response, origin: origin, method: request.method, path: request.path) }
    }
  }

  private func respond(_ response: HTTPResponse, origin: String? = nil, method: String, path: String) {
    var response = response
    if let origin {
      response.headers += [
        ("Access-Control-Allow-Origin", origin),
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
        ("Vary", "Origin"),
      ]
    }
    response.headers.append(("Connection", "close"))
    server?.onEvent(.request(method: method, path: path, status: response.status))
    connection.send(
      content: response.serialized(),
      completion: .contentProcessed { [weak self] _ in self?.close() })
  }

  // MARK: - WebSocket

  private func upgrade(_ request: HTTPRequest) {
    guard ["/", "/v1/stream"].contains(request.path) else {
      respond(.error("WebSocket endpoint is /v1/stream.", status: 404), method: "GET", path: request.path)
      return
    }
    guard let key = request.header("sec-websocket-key"), request.header("sec-websocket-version") == "13" else {
      respond(.error("Bad WebSocket handshake.", status: 400), method: "GET", path: request.path)
      return
    }
    let response = HTTPResponse(
      status: 101,
      headers: [
        ("Upgrade", "websocket"),
        ("Connection", "Upgrade"),
        ("Sec-WebSocket-Accept", WebSocket.acceptKey(for: key)),
      ])
    connection.send(content: response.serialized(), completion: .idempotent)
    isWebSocket = true
    server?.onEvent(.streamOpened(id: id, client: request.header("origin") ?? request.header("user-agent") ?? "client"))
    sendJSON(["type": "hello", "server": "hark", "version": harkVersion])

    // Optional shortcut: ws://127.0.0.1:8082/v1/stream?language=ja-JP&sample_rate=16000
    if let language = request.query["language"] {
      startTranscriber(locale: language, sampleRate: Double(request.query["sample_rate"] ?? "") ?? 16000)
    }
    if !buffer.isEmpty { processFrames() }
  }

  private func processFrames() {
    do {
      while let (frame, used) = try WebSocket.parseFrame(buffer) {
        buffer.removeFirst(used)
        guard let message = assembler.consume(frame) else { continue }
        handle(message)
        if closed { return }
      }
    } catch {
      sendFrame(.close, WebSocket.closePayload(code: 1002, reason: "protocol error"))
      close()
    }
  }

  private func handle(_ message: WebSocketMessageAssembler.Message) {
    switch message {
    case .binary(let data):
      transcriber?.append(pcm16: data)
    case .text(let text):
      guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let type = json["type"] as? String
      else {
        sendJSON(["type": "error", "message": "Expected a JSON message with a 'type' field."])
        return
      }
      switch type {
      case "start":
        let locale = (json["locale"] as? String) ?? (json["language"] as? String)
        let rate = (json["sample_rate"] as? Double) ?? (json["sample_rate"] as? Int).map(Double.init) ?? 16000
        startTranscriber(locale: locale, sampleRate: rate)
      case "stop":
        let current = transcriber
        transcriber = nil
        Task {
          await current?.finish()
          self.sendJSON(["type": "stopped"])
        }
      default:
        sendJSON(["type": "error", "message": "Unknown message type '\(type)'."])
      }
    case .ping(let payload):
      sendFrame(.pong, payload)
    case .pong:
      break
    case .close:
      sendFrame(.close, WebSocket.closePayload(code: 1000))
      let current = transcriber
      transcriber = nil
      Task {
        await current?.finish()
        self.close()
      }
    }
  }

  private func startTranscriber(locale: String?, sampleRate: Double) {
    let previous = transcriber
    let streamID = id
    let server = self.server
    let transcriber = StreamTranscriber { [weak self] event in
      guard let self else { return }
      switch event {
      case .downloadingModel(let locale):
        server?.onEvent(.modelDownloading(locale: locale))
        self.sendJSON(["type": "status", "message": "Downloading the speech model for \(locale)…"])
      case .ready(let locale):
        server?.onEvent(.streamReady(id: streamID, locale: locale))
        self.sendJSON(["type": "ready", "locale": locale])
      case .partial(let text):
        self.sendJSON(["type": "partial", "text": text])
      case .final(let text, let start, let end):
        server?.onEvent(.transcript(source: .stream, locale: "", text: text))
        self.sendJSON(["type": "final", "text": text, "start": roundMs(start), "end": roundMs(end)])
      case .error(let message):
        self.sendJSON(["type": "error", "message": message])
      }
    }
    self.transcriber = transcriber
    Task {
      await previous?.finish()
      do {
        try await transcriber.start(locale: locale, sampleRate: sampleRate)
      } catch {
        self.sendJSON(["type": "error", "message": error.localizedDescription])
      }
    }
  }

  func sendJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    sendFrame(.text, data)
  }

  private func sendFrame(_ opcode: WebSocket.Opcode, _ payload: Data) {
    connection.send(content: WebSocket.encode(.init(opcode: opcode, payload: payload)), completion: .idempotent)
  }

  func close() {
    queue.async {
      guard !self.closed else { return }
      self.closed = true
      if self.isWebSocket { self.server?.onEvent(.streamClosed(id: self.id)) }
      let current = self.transcriber
      self.transcriber = nil
      Task { await current?.finish() }
      self.connection.cancel()
      self.server?.remove(self)
    }
  }
}
