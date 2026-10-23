// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BKLight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BKLight",
            path: "Sources/BKLight"
        ),
        .testTarget(
            name: "BKLightTests",
            dependencies: ["BKLight"],
            path: "Tests/BKLightTests"
        ),
    ]
)
