import Foundation

/// Parser for `multipart/form-data` bodies (what OpenAI SDKs send for /v1/audio/transcriptions).
public enum Multipart {
  public struct Part: Sendable {
    public var name: String
    public var filename: String?
    public var contentType: String?
    public var data: Data

    public var stringValue: String { String(decoding: data, as: UTF8.self) }
  }

  public enum ParseError: Error, Equatable {
    case missingBoundary
    case malformed
  }

  /// Extracts the boundary from a `Content-Type: multipart/form-data; boundary=...` header.
  public static func boundary(from contentType: String?) -> String? {
    guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else { return nil }
    for param in contentType.split(separator: ";").dropFirst() {
      let pair = param.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if pair.count == 2, pair[0].lowercased() == "boundary" {
        return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    }
    return nil
  }

  public static func parse(_ body: Data, boundary: String) throws -> [Part] {
    let delimiter = Data("--\(boundary)".utf8)
    let crlf = Data("\r\n".utf8)
    let headerEnd = Data("\r\n\r\n".utf8)

    guard var cursor = body.range(of: delimiter)?.upperBound else { throw ParseError.malformed }
    var parts: [Part] = []
    while true {
      // "--" after the delimiter marks the end of the body.
      if body[cursor...].starts(with: Data("--".utf8)) { break }
      guard body[cursor...].starts(with: crlf) else { throw ParseError.malformed }
      cursor += crlf.count

      guard let headRange = body.range(of: headerEnd, in: cursor..<body.endIndex) else { throw ParseError.malformed }
      let head = String(decoding: body[cursor..<headRange.lowerBound], as: UTF8.self)
      let contentStart = headRange.upperBound

      guard let next = body.range(of: crlf + delimiter, in: contentStart..<body.endIndex) else {
        throw ParseError.malformed
      }
      let content = Data(body[contentStart..<next.lowerBound])

      var name: String?
      var filename: String?
      var contentType: String?
      for line in head.components(separatedBy: "\r\n") {
        let lower = line.lowercased()
        if lower.hasPrefix("content-disposition:") {
          name = attribute("name", in: line)
          filename = attribute("filename", in: line)
        } else if lower.hasPrefix("content-type:") {
          contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
        }
      }
      if let name { parts.append(Part(name: name, filename: filename, contentType: contentType, data: content)) }
      cursor = next.upperBound
    }
    return parts
  }

  static func attribute(_ key: String, in line: String) -> String? {
    // Matches key="value" (value may contain ';'). The leading space/; avoids matching "filename" for "name".
    let pattern = "(?:^|[;\\s])\(key)=\"([^\"]*)\""
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let range = Range(match.range(at: 1), in: line)
    else { return nil }
    return String(line[range])
  }
}
