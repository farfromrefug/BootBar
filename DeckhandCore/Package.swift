// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeckhandCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeckhandCore", targets: ["DeckhandCore"])
    ],
    targets: [
        .target(name: "DeckhandCore"),
        .testTarget(name: "DeckhandCoreTests", dependencies: ["DeckhandCore"])
    ]
)
