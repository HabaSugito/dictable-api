import CryptoKit
import Foundation

/// Minimal RFC 6455 framing: enough for a localhost server talking to browsers and SDKs.
public enum WebSocket {
  public enum Opcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
  }

  public struct Frame: Equatable, Sendable {
    public var fin: Bool
    public var opcode: Opcode
    public var payload: Data

    public init(fin: Bool = true, opcode: Opcode, payload: Data) {
      self.fin = fin
      self.opcode = opcode
      self.payload = payload
    }
  }

  public enum FrameError: Error, Equatable {
    case reservedBits
    case unknownOpcode(UInt8)
    case unmaskedClientFrame
    case tooLarge
    case fragmentedControlFrame
  }

  static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  /// The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`.
  public static func acceptKey(for key: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
    return Data(digest).base64EncodedString()
  }

  /// Parses one frame from the front of `buffer`. Returns `nil` if more bytes are needed.
  /// Frames from clients must be masked (RFC 6455 §5.1).
  public static func parseFrame(_ buffer: Data, requireMask: Bool = true, maxPayload: Int = 16 * 1024 * 1024) throws -> (
    Frame, Int
  )? {
    let bytes = [UInt8](buffer)
    guard bytes.count >= 2 else { return nil }
    let b0 = bytes[0]
    let b1 = bytes[1]
    guard b0 & 0x70 == 0 else { throw FrameError.reservedBits }
    guard let opcode = Opcode(rawValue: b0 & 0x0F) else { throw FrameError.unknownOpcode(b0 & 0x0F) }
    let fin = b0 & 0x80 != 0
    let masked = b1 & 0x80 != 0
    if requireMask && !masked { throw FrameError.unmaskedClientFrame }
    if opcode.rawValue >= 0x8 && !fin { throw FrameError.fragmentedControlFrame }

    var offset = 2
    var length = UInt64(b1 & 0x7F)
    if length == 126 {
      guard bytes.count >= offset + 2 else { return nil }
      length = UInt64(bytes[offset]) << 8 | UInt64(bytes[offset + 1])
      offset += 2
    } else if length == 127 {
      guard bytes.count >= offset + 8 else { return nil }
      length = bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
      offset += 8
    }
    guard length <= UInt64(maxPayload) else { throw FrameError.tooLarge }

    var mask: [UInt8] = []
    if masked {
      guard bytes.count >= offset + 4 else { return nil }
      mask = Array(bytes[offset..<(offset + 4)])
      offset += 4
    }
    let count = Int(length)
    guard bytes.count >= offset + count else { return nil }
    var payload = Array(bytes[offset..<(offset + count)])
    if masked {
      for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
    }
    return (Frame(fin: fin, opcode: opcode, payload: Data(payload)), offset + count)
  }

  /// Encodes a frame. Servers send unmasked frames; pass `mask` only to build client frames (tests, clients).
  public static func encode(_ frame: Frame, mask: [UInt8]? = nil) -> Data {
    var out: [UInt8] = [(frame.fin ? 0x80 : 0) | frame.opcode.rawValue]
    let maskBit: UInt8 = mask == nil ? 0 : 0x80
    let count = frame.payload.count
    if count < 126 {
      out.append(maskBit | UInt8(count))
    } else if count <= 0xFFFF {
      out.append(maskBit | 126)
      out.append(UInt8(count >> 8))
      out.append(UInt8(count & 0xFF))
    } else {
      out.append(maskBit | 127)
      for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF)) }
    }
    var payload = [UInt8](frame.payload)
    if let mask {
      out.append(contentsOf: mask)
      for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
    }
    out.append(contentsOf: payload)
    return Data(out)
  }

  public static func closePayload(code: UInt16, reason: String = "") -> Data {
    var data = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    data.append(Data(reason.utf8.prefix(120)))
    return data
  }
}

/// Reassembles fragmented messages.
public struct WebSocketMessageAssembler {
  public enum Message: Equatable {
    case text(String)
    case binary(Data)
    case close(code: UInt16?)
    case ping(Data)
    case pong(Data)
  }

  private var opcode: WebSocket.Opcode?
  private var pending = Data()

  public init() {}

  public mutating func consume(_ frame: WebSocket.Frame) -> Message? {
    switch frame.opcode {
    case .close:
      let p = [UInt8](frame.payload)
      return .close(code: p.count >= 2 ? UInt16(p[0]) << 8 | UInt16(p[1]) : nil)
    case .ping: return .ping(frame.payload)
    case .pong: return .pong(frame.payload)
    case .text, .binary:
      opcode = frame.opcode
      pending = frame.payload
    case .continuation:
      pending.append(frame.payload)
    }
    guard frame.fin, let kind = opcode else { return nil }
    defer {
      opcode = nil
      pending = Data()
    }
    if kind == .text { return .text(String(decoding: pending, as: UTF8.self)) }
    return .binary(pending)
  }
}
