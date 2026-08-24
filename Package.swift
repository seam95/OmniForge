// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OmniForge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OmniForge", targets: ["OmniForge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.10.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "OmniForge",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/OmniForge",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "OmniForgeTests",
            dependencies: [
                "OmniForge",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/OmniForgeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
