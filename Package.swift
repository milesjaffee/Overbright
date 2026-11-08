// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Overbright",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Overbright", targets: ["Overbright"])
    ],
    targets: [
        .executableTarget(name: "Overbright", path: "Sources/Overbright")
    ]
)
