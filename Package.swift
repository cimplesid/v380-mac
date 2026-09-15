// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenV380",
    platforms: [.macOS(.v13)],
    targets: [
        // Native implementation of the V380 (Macrovideo) camera protocol on TCP 8800.
        .target(name: "V380"),
        // Menu bar app: one click (or ⌃⌥V) opens the live feed.
        .executableTarget(name: "OpenV380", dependencies: ["V380"]),
        // Command-line probe used to test the protocol against a real camera.
        .executableTarget(name: "v380probe", dependencies: ["V380"]),
    ]
)
