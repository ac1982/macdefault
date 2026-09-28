// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "macdefault",
  platforms: [.macOS(.v12)],
  products: [.executable(name: "macdefault", targets: ["MacDefaultCLI"])],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
  ],
  targets: [
    .target(name: "MacDefaultCore"),
    .target(name: "MacDefaultSystem", dependencies: ["MacDefaultCore"]),
    .executableTarget(
      name: "MacDefaultCLI",
      dependencies: [
        "MacDefaultCore", "MacDefaultSystem",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "MacDefaultCoreTests", dependencies: ["MacDefaultCore"]),
    .testTarget(name: "MacDefaultSystemTests", dependencies: ["MacDefaultSystem"]),
    .testTarget(name: "MacDefaultCLITests", dependencies: ["MacDefaultCLI"]),
  ]
)
