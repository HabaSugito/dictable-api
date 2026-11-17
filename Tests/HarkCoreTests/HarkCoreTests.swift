import Foundation
import Testing

@testable import HarkCore

@Suite("HTTP parser")
struct HTTPParserTests {
  @Test func parsesRequestWithBodyAndQuery() throws {
    let raw = Data("POST /v1/audio/transcriptions?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8082\r\nContent-Length: 5\r\nX-Test: a\r\n\r\nhelloEXTRA".utf8)
    let (request, used) = try #require(try HTTPParser.parse(raw))
    #expect(request.method == "POST")
    #expect(request.path == "/v1/audio/transcriptions")
    #expect(request.query["x"] == "1")
    #expect(request.header("x-test") == "a")
    #expect(request.header("X-TEST") == "a")
    #expect(String(decoding: request.body, as: UTF8.self) == "hello")
    #expect(used == raw.count - "EXTRA".count)
  }

  @Test func waitsForCompleteHeadersAndBody() throws {
    #expect(try HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == nil)
    #expect(try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)) == nil)
  }

  @Test func rejectsBadInput() {
    #expect(throws: HTTPError.self) { try HTTPParser.parse(Data("NONSENSE\r\n\r\n".utf8)) }
    #expect(throws: HTTPError.payloadTooLarge) {
      try HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n".utf8), maxBodySize: 10)
    }
    #expect(throws: HTTPError.self) {
      try HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
    }
  }

  @Test func detectsWebSocketUpgrade() throws {
    let raw = Data("GET /v1/stream HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n\r\n".utf8)
    let (request, _) = try #require(try HTTPParser.parse(raw))
    #expect(request.isWebSocketUpgrade)
  }

  @Test func serializesResponse() {
    let text = String(decoding: HTTPResponse.json(["ok": true]).serialized(), as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(text.contains("Content-Length: 11\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
  }
}

@Suite("WebSocket framing")
struct WebSocketTests {
  @Test func acceptKeyMatchesRFC6455Example() {
    #expect(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  }

  @Test(arguments: [0, 5, 125, 126, 300, 65535, 70000])
  func roundTripsMaskedFrames(size: Int) throws {
    let payload = Data((0..<size).map { UInt8($0 & 0xFF) })
    let encoded = WebSocket.encode(.init(opcode: .binary, payload: payload), mask: [1, 2, 3, 4])
    let (frame, used) = try #require(try WebSocket.parseFrame(encoded))
    #expect(frame.payload == payload)
    #expect(frame.opcode == .binary)
    #expect(used == encoded.count)
    // Incomplete input asks for more bytes instead of failing.
    #expect(try WebSocket.parseFrame(encoded.prefix(encoded.count - 1)) == nil)
  }

  @Test func rejectsUnmaskedClientFrames() {
    let unmasked = WebSocket.encode(.init(opcode: .text, payload: Data("hi".utf8)))
    #expect(throws: WebSocket.FrameError.unmaskedClientFrame) { try WebSocket.parseFrame(unmasked) }
  }

  @Test func reassemblesFragmentedText() {
    var assembler = WebSocketMessageAssembler()
    #expect(assembler.consume(.init(fin: false, opcode: .text, payload: Data("Hel".utf8))) == nil)
    // Control frames may arrive between fragments.
    #expect(assembler.consume(.init(opcode: .ping, payload: Data())) == .ping(Data()))
    #expect(assembler.consume(.init(fin: true, opcode: .continuation, payload: Data("lo".utf8))) == .text("Hello"))
  }

  @Test func readsCloseCode() {
    var assembler = WebSocketMessageAssembler()
    let message = assembler.consume(.init(opcode: .close, payload: WebSocket.closePayload(code: 1000, reason: "bye")))
    #expect(message == .close(code: 1000))
  }
}

@Suite("Multipart")
struct MultipartTests {
  @Test func parsesOpenAIStyleUpload() throws {
    let boundary = "----hark1234"
    let audio = Data([0x52, 0x49, 0x46, 0x46, 0x0D, 0x0A, 0x2D, 0x2D, 0x00])  // contains CRLF and "--"
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n".utf8))
    body.append(
      Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a; b.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
          .utf8))
    body.append(audio)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    #expect(Multipart.boundary(from: "multipart/form-data; boundary=\"\(boundary)\"") == boundary)
    let parts = try Multipart.parse(body, boundary: boundary)
    #expect(parts.map(\.name) == ["model", "file"])
    #expect(parts[0].stringValue == "whisper-1")
    #expect(parts[1].filename == "a; b.wav")
    #expect(parts[1].contentType == "audio/wav")
    #expect(parts[1].data == audio)
  }

  @Test func rejectsGarbage() {
    #expect(throws: Multipart.ParseError.self) { try Multipart.parse(Data("nope".utf8), boundary: "x") }
    #expect(Multipart.boundary(from: "application/json") == nil)
  }
}

@Suite("Access policy")
struct AccessPolicyTests {
  @Test(arguments: ["127.0.0.1:8082", "localhost:8082", "localhost", "[::1]:8082"])
  func allowsLoopbackHosts(host: String) {
    #expect(AccessPolicy.isAllowedHost(host))
  }

  @Test(arguments: [nil, "attacker.com", "127.0.0.1.evil.com:8082", "192.168.0.2:8082"])
  func blocksOtherHosts(host: String?) {
    #expect(!AccessPolicy.isAllowedHost(host))
  }

  @Test func origins() {
    #expect(AccessPolicy.isAllowedOrigin(nil))  // curl, SDKs
    #expect(AccessPolicy.isAllowedOrigin("chrome-extension://abcdef"))
    #expect(AccessPolicy.isAllowedOrigin("http://localhost:3000"))
    #expect(AccessPolicy.isAllowedOrigin("http://127.0.0.1"))
    #expect(!AccessPolicy.isAllowedOrigin("https://evil.example"))
    #expect(!AccessPolicy.isAllowedOrigin("http://localhost.evil.example"))
    #expect(!AccessPolicy.isAllowedOrigin("null"))
  }
}

@Suite("Output formats")
struct OutputFormatTests {
  let segments = [
    TranscriptSegment(start: 0, end: 1.5, text: "Hello."),
    TranscriptSegment(start: 3661.25, end: 3662, text: "Bye."),
  ]

  @Test func srt() {
    #expect(
      ResponseFormat.srt(segments)
        == "1\n00:00:00,000 --> 00:00:01,500\nHello.\n\n2\n01:01:01,250 --> 01:01:02,000\nBye.\n")
  }

  @Test func vtt() {
    #expect(ResponseFormat.vtt(segments).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello.\n"))
  }

  @Test func joinsJapaneseWithoutSpaces() {
    #expect(FileTranscriber.joinSegments(["こんにちは。", "元気です。"], locale: Locale(identifier: "ja_JP")) == "こんにちは。元気です。")
    #expect(FileTranscriber.joinSegments(["Hi.", "Bye."], locale: Locale(identifier: "en_US")) == "Hi. Bye.")
  }

  @Test func roundsToMilliseconds() {
    #expect(roundMs(21.539999999999999) == 21.54)
    #expect(roundMs(.nan) == 0)
  }
}
