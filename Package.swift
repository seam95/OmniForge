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
        // 烟花庆祝粒子引擎；锁定与 TokenTracker 相同的 revision，避免上游变动引入回归。
        .package(url: "https://github.com/zats/Vortex", revision: "ef5392088d4aeb255c4eee83157dbdafcd31bf07"),
        // 自动更新框架：binaryTarget 形式，附 EdDSA 工具与 Sparkle.framework（非沙盒应用，无需启用 XPC 服务）。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "OmniForgeSMC",
            path: "Sources/OmniForgeSMC",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "OmniForge",
            dependencies: [
                "OmniForgeSMC",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Vortex", package: "Vortex"),
                .product(name: "Sparkle", package: "Sparkle"),
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
                "OmniForgeSMC",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Vortex", package: "Vortex"),
            ],
            path: "Tests/OmniForgeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
