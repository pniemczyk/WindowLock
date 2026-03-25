// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "WindowLock",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "WindowLock",
      path: "Sources/WindowLock",
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("Cocoa")
      ]
    )
  ]
)
