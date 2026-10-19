// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoBorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NoBorderEngine"),
        .target(name: "NoBorderLogic", dependencies: ["NoBorderEngine"]),
        .executableTarget(name: "noborder-probe", dependencies: ["NoBorderEngine"]),
        .executableTarget(name: "NoBorder", dependencies: ["NoBorderEngine", "NoBorderLogic"]),
        .testTarget(name: "NoBorderEngineTests", dependencies: ["NoBorderEngine"]),
        .testTarget(name: "NoBorderLogicTests", dependencies: ["NoBorderLogic"]),
    ]
)
