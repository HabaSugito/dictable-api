import Foundation

/// The server only listens on 127.0.0.1, but any web page you open could still try to reach it.
/// These checks stop random websites from using your microphone-free speech engine:
///  - `Host` must be a loopback name (blocks DNS-rebinding attacks).
///  - Browser requests (those with an `Origin`) must come from an extension or a localhost page.
public enum AccessPolicy {
  public static let allowedOriginPrefixes = [
    "chrome-extension://",
    "moz-extension://",
    "safari-web-extension://",
    "http://localhost",
    "https://localhost",
    "http://127.0.0.1",
    "https://127.0.0.1",
    "http://[::1]",
  ]

  public static func isAllowedHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    let name: String
    if host.hasPrefix("[") {
      name = String(host.prefix { $0 != "]" }) + "]"
    } else {
      name = String(host.split(separator: ":").first ?? "")
    }
    return ["localhost", "127.0.0.1", "[::1]"].contains(name)
  }

  /// Requests without an Origin header come from non-browser clients (curl, SDKs) and are allowed.
  public static func isAllowedOrigin(_ origin: String?) -> Bool {
    guard let origin = origin?.lowercased(), origin != "null" else { return origin == nil }
    return allowedOriginPrefixes.contains { prefix in
      guard origin.hasPrefix(prefix) else { return false }
      // "http://localhost.evil.com" must not pass: the next character has to end the host.
      let rest = origin.dropFirst(prefix.count)
      return prefix.hasSuffix("://") || rest.isEmpty || rest.hasPrefix(":") || rest.hasPrefix("/")
    }
  }
}
