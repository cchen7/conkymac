// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConkyMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ConkyMac", targets: ["ConkyMac"])],
    targets: [
        .target(name: "CLua", exclude: ["LICENSE"], cSettings: [.define("LUA_USE_MACOSX")]),
        .target(name: "ConkyLuaBridge", dependencies: ["CLua"], cSettings: [.define("LUA_USE_MACOSX")],
                linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("CoreText"), .linkedFramework("CoreFoundation")]),
        .target(name: "CSystemPrivate", linkerSettings: [.linkedLibrary("IOReport")]),
        .target(name: "ConkyMacCore", dependencies: ["CSystemPrivate"]),
        .executableTarget(name: "ConkyMac", dependencies: ["ConkyMacCore", "ConkyLuaBridge"]),
        .testTarget(name: "ConkyMacCoreTests", dependencies: ["ConkyMacCore"]),
        .testTarget(name: "ConkyMacTests", dependencies: ["ConkyMac", "ConkyMacCore"]),
        .testTarget(name: "ConkyLuaBridgeTests", dependencies: ["ConkyLuaBridge"])
    ]
)
