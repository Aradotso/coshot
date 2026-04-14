// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "coshot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "coshot",
            resources: [.process("Resources")]
        )
    ]
)
