// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Goldfish",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Goldfish", targets: ["Goldfish"])
    ],
    targets: [
        .executableTarget(name: "Goldfish", resources: [.process("Resources")]),
        .testTarget(name: "GoldfishTests", dependencies: ["Goldfish"], path: "Tests/GoldfishTests")
    ]
)
