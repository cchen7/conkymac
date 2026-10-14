// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConkyMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ConkyMac", targets: ["ConkyMac"])],
    targets: [
        .target(name: "CLua", exclude: ["LICENSE"], cSettings: [.define("LUA_USE_MACOSX")]),
        .target(name: "ConkyLuaBridge", dependencies: ["CLua"], cSettings: [.define("LUA_USE_MACOSX")],
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "ConkyMacCore"),
        .executableTarget(name: "ConkyMac", dependencies: ["ConkyMacCore", "ConkyLuaBridge"]),
        .testTarget(name: "ConkyMacCoreTests", dependencies: ["ConkyMacCore"]),
        .testTarget(name: "ConkyLuaBridgeTests", dependencies: ["ConkyLuaBridge"])
    ]
)
