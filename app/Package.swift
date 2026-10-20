// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "FileTree",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "FileTree", path: "Sources/FileTree", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
