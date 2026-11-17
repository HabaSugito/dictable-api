// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
  name: "HarkServer",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "HarkServer", targets: ["HarkServer"])
  ],
  targets: [
    // Networking (HTTP + WebSocket) and the on-device speech engine. No UI, no dependencies.
    .target(name: "HarkCore", path: "Sources/HarkCore", swiftSettings: settings),
    // The menu bar app.
    .executableTarget(
      name: "HarkServer", dependencies: ["HarkCore"], path: "Sources/HarkServer", swiftSettings: settings),
    .testTarget(
      name: "HarkCoreTests", dependencies: ["HarkCore"], path: "Tests/HarkCoreTests", swiftSettings: settings),
  ]
)
