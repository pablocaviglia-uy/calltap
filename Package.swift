// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CallTap",
    // Core Audio process taps arrived in macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        // Pure logic (file naming, track alignment), unit-tested.
        .target(name: "CallTapCore"),
        // The menu bar app: call detection, process tap, microphone, notifications.
        .executableTarget(name: "CallTap", dependencies: ["CallTapCore"]),
        .testTarget(name: "CallTapCoreTests", dependencies: ["CallTapCore"]),
    ]
)
