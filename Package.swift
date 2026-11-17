// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
  name: "DictableAPI",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "DictableAPI", targets: ["DictableAPI"])
  ],
  targets: [
    // Networking (HTTP + WebSocket) and the on-device speech engine. No UI, no dependencies.
    .target(name: "DictableCore", path: "Sources/DictableCore", swiftSettings: settings),
    // The menu bar app.
    .executableTarget(
      name: "DictableAPI", dependencies: ["DictableCore"], path: "Sources/DictableAPI", swiftSettings: settings),
    .testTarget(
      name: "DictableCoreTests", dependencies: ["DictableCore"], path: "Tests/DictableCoreTests", swiftSettings: settings),
  ]
)
