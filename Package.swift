// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevEcoCodeDesktop",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "DevEcoCodeDesktop",
            path: "Sources/DevEcoCodeDesktop"
        ),
        .testTarget(
            name: "DevEcoCodeDesktopTests",
            dependencies: ["DevEcoCodeDesktop"],
            path: "Tests/DevEcoCodeDesktopTests"
        ),
    ]
)
