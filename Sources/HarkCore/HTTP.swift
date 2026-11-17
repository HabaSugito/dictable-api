import Foundation

public struct HTTPRequest: Sendable {
  public var method: String
  public var path: String
  public var query: [String: String]
  /// Header names are lowercased.
  public var headers: [String: String]
  public var body: Data

  public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
  }

  public func header(_ name: String) -> String? { headers[name.lowercased()] }

  public var isWebSocketUpgrade: Bool {
    header("upgrade")?.lowercased() == "websocket"
      && (header("connection")?.lowercased().contains("upgrade") ?? false)
  }
}

public enum HTTPError: Error, Equatable {
  case malformed(String)
  case payloadTooLarge
  case unsupported(String)
}

public enum HTTPParser {
  static let headerTerminator = Data("\r\n\r\n".utf8)

  /// Parses one request from the front of `buffer`.
  /// Returns `nil` while the request is still incomplete, otherwise the request and the number of bytes it used.
  public static func parse(_ buffer: Data, maxBodySize: Int = 200 * 1024 * 1024) throws -> (HTTPRequest, Int)? {
    guard let headerEnd = buffer.range(of: headerTerminator) else {
      if buffer.count > 64 * 1024 { throw HTTPError.malformed("header too large") }
      return nil
    }
    let headData = buffer[buffer.startIndex..<headerEnd.lowerBound]
    guard let head = String(data: headData, encoding: .utf8) else { throw HTTPError.malformed("header is not UTF-8") }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
      throw HTTPError.malformed("bad request line")
    }

    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed("bad header line") }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
    }

    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      throw HTTPError.unsupported("chunked transfer encoding")
    }
    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0 else { throw HTTPError.malformed("bad content-length") }
    guard length <= maxBodySize else { throw HTTPError.payloadTooLarge }

    let bodyStart = headerEnd.upperBound
    guard buffer.endIndex - bodyStart >= length else { return nil }
    let body = Data(buffer[bodyStart..<(bodyStart + length)])

    let target = String(requestLine[1])
    let components = URLComponents(string: target)
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

    let request = HTTPRequest(
      method: String(requestLine[0]).uppercased(),
      path: components?.path ?? target,
      query: query,
      headers: headers,
      body: body)
    return (request, bodyStart + length - buffer.startIndex)
  }
}

public struct HTTPResponse: Sendable {
  public var status: Int
  public var headers: [(String, String)]
  public var body: Data

  public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
  }

  public static func text(_ string: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
    HTTPResponse(status: status, headers: [("Content-Type", contentType)], body: Data(string.utf8))
  }

  /// OpenAI-style error body: {"error": {"message": ..., "type": ...}}
  public static func error(_ message: String, status: Int, type: String = "invalid_request_error") -> HTTPResponse {
    json(["error": ["message": message, "type": type]], status: status)
  }

  public static func reason(for status: Int) -> String {
    switch status {
    case 101: "Switching Protocols"
    case 200: "OK"
    case 204: "No Content"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 413: "Payload Too Large"
    case 415: "Unsupported Media Type"
    case 422: "Unprocessable Content"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 503: "Service Unavailable"
    default: "Unknown"
    }
  }

  public func serialized() -> Data {
    var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(for: status))\r\n"
    var hasLength = false
    for (name, value) in headers {
      if name.lowercased() == "content-length" { hasLength = true }
      head += "\(name): \(value)\r\n"
    }
    if status != 101 && !hasLength { head += "Content-Length: \(body.count)\r\n" }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
  }
}
