// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConkyMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ConkyMac", targets: ["ConkyMac"])],
    targets: [
        .target(name: "CSystemPrivate", linkerSettings: [.linkedLibrary("IOReport")]),
        .target(name: "ConkyMacCore", dependencies: ["CSystemPrivate"]),
        .executableTarget(name: "ConkyMac", dependencies: ["ConkyMacCore"]),
        .testTarget(name: "ConkyMacCoreTests", dependencies: ["ConkyMacCore"])
    ]
)
