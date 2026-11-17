import Darwin
import Foundation

/// Checks whether a TCP port can be used on 127.0.0.1 before starting the server,
/// so a clash with another app is reported clearly (with a free alternative) instead of failing later.
public enum PortProbe {
  public static let validRange: ClosedRange<UInt16> = 1024...65535

  /// True if nothing is listening on 127.0.0.1:`port` or on the wildcard address for that port.
  public static func isAvailable(_ port: UInt16) -> Bool {
    canBind(port, address: "127.0.0.1") && canBind(port, address: "0.0.0.0")
  }

  /// The first free port after `port`, skipping `excluding` (ports you already know are taken).
  public static func firstAvailable(after port: UInt16, excluding: Set<UInt16> = [], attempts: Int = 100) -> UInt16? {
    var candidate = port
    for _ in 0..<attempts {
      candidate = candidate >= validRange.upperBound ? validRange.lowerBound : candidate + 1
      if !excluding.contains(candidate), isAvailable(candidate) { return candidate }
    }
    return nil
  }

  /// Parses user input like "8083". Returns nil for anything outside 1024–65535.
  public static func parse(_ text: String) -> UInt16? {
    guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), validRange.contains(value) else {
      return nil
    }
    return value
  }

  private static func canBind(_ port: UInt16, address: String) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    // SO_REUSEADDR so connections still in TIME_WAIT (a port that was just freed) don't count as "in use".
    // A socket that is actually listening on the same address still makes bind fail, and checking both
    // 127.0.0.1 and 0.0.0.0 catches listeners on either the loopback or the wildcard address.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(address)
    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0
  }
}
