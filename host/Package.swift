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
        .executable(name: "msl", targets: ["msl"]),
        .executable(name: "msl-presenter", targets: ["msl-presenter"]),
        .executable(name: "msl-menubar", targets: ["msl-menubar"]),
        .executable(name: "msl-fskit", targets: ["msl-fskit"]),
        .executable(name: "msl-fskit-probe-server", targets: ["msl-fskit-probe-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "CMSLSys"
        ),
        .target(
            name: "MSLFSWire",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MSLCore",
            dependencies: ["CMSLSys", "MSLFSWire"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MSLGui",
            dependencies: ["MSLCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "msl",
            dependencies: [
                "MSLCore",
                "MSLFSWire",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        // The presenter is the only host binary that links AppKit; keeping it a
        // separate executable is what lets `msl` (CLI + daemon) stay AppKit-free.
        .executableTarget(
            name: "msl-presenter",
            dependencies: ["MSLCore", "MSLGui"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MSLMenuBarCore",
            dependencies: ["MSLCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "msl-menubar",
            dependencies: ["MSLCore", "MSLMenuBarCore"],
            swiftSettings: swiftSettings
        ),
        // Type-checks the appex sources in `swift build`; the SHIPPED appex is
        // built by xcodebuild (host/fskit-appex.yml), because SwiftPM cannot emit
        // a working ExtensionKit extension (AppExtension.main() returns instead of
        // running the service loop). See the Makefile `appex` target.
        .executableTarget(
            name: "msl-fskit",
            dependencies: ["MSLFSWire"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "msl-fskit-probe-server",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MSLCoreTests",
            dependencies: ["MSLCore", "MSLFSWire"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MSLMenuBarCoreTests",
            dependencies: ["MSLMenuBarCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MSLMenuBarAppTests",
            dependencies: ["msl-menubar"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MSLCommandTests",
            dependencies: ["msl"],
            swiftSettings: swiftSettings
        ),
    ]
)
