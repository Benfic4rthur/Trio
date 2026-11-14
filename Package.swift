// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Trio",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TrioCore", targets: ["TrioCore"])],
    targets: [
        .target(name: "TrioCore"),
        .target(name: "Trio", dependencies: ["TrioCore"]),
        .testTarget(name: "TrioCoreTests", dependencies: ["TrioCore"])
    ],
    swiftLanguageVersions: [.v5]
)
