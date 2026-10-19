// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoBorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NoBorderCore"),
        .target(name: "NoBorderEngine"),
        .executableTarget(name: "noborder-probe", dependencies: ["NoBorderEngine"]),
        .executableTarget(name: "NoBorder", dependencies: ["NoBorderCore", "NoBorderEngine"]),
        .testTarget(name: "NoBorderCoreTests", dependencies: ["NoBorderCore"]),
        .testTarget(name: "NoBorderEngineTests", dependencies: ["NoBorderEngine"]),
    ]
)
