// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProteinKit",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProteinKit", targets: ["ProteinKit"]),
    ],
    targets: [
        .target(
            name: "ProteinKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ProteinKitTests",
            dependencies: ["ProteinKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
