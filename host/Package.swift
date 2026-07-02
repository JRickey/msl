// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "msl",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "msl", targets: ["msl"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "MSLCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "msl",
            dependencies: [
                "MSLCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MSLCoreTests",
            dependencies: ["MSLCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
