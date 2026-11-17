import Foundation

public struct TranscriptSegment: Sendable, Equatable {
  public var start: Double
  public var end: Double
  public var text: String

  public init(start: Double, end: Double, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }
}

/// Output formats compatible with OpenAI's `response_format` parameter.
public enum ResponseFormat: String, CaseIterable, Sendable {
  case json
  case text
  case verboseJSON = "verbose_json"
  case srt
  case vtt

  public static func timestamp(_ seconds: Double, separator: Character) -> String {
    let ms = Int((max(0, seconds) * 1000).rounded())
    let h = ms / 3_600_000
    let m = ms / 60_000 % 60
    let s = ms / 1000 % 60
    return String(format: "%02d:%02d:%02d%@%03d", h, m, s, String(separator), ms % 1000)
  }

  public static func srt(_ segments: [TranscriptSegment]) -> String {
    segments.enumerated().map { i, seg in
      "\(i + 1)\n\(timestamp(seg.start, separator: ",")) --> \(timestamp(seg.end, separator: ","))\n\(seg.text)\n"
    }.joined(separator: "\n")
  }

  public static func vtt(_ segments: [TranscriptSegment]) -> String {
    "WEBVTT\n\n"
      + segments.map { seg in
        "\(timestamp(seg.start, separator: ".")) --> \(timestamp(seg.end, separator: "."))\n\(seg.text)\n"
      }.joined(separator: "\n")
  }
}
