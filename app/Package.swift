// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoBorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NoBorderEngine"),
        .target(name: "NoBorderNative", dependencies: ["NoBorderEngine"]),
        .target(name: "NoBorderLogic", dependencies: ["NoBorderEngine"]),
        .executableTarget(name: "noborder-probe", dependencies: ["NoBorderNative"]),
        .executableTarget(name: "noborder-tool"),
        .executableTarget(name: "noborder-e2e", dependencies: ["NoBorderEngine", "NoBorderLogic", "NoBorderNative"]),
        .executableTarget(name: "NoBorder", dependencies: ["NoBorderEngine", "NoBorderLogic", "NoBorderNative"]),
        .testTarget(name: "NoBorderNativeTests", dependencies: ["NoBorderNative"]),
        .testTarget(name: "NoBorderLogicTests", dependencies: ["NoBorderLogic"]),
    ]
)
