// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BadgersBLELock",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "BadgersBLELock", path: "Sources/BadgersBLELock")
    ]
)
