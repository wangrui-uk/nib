// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GrammarAI",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Automatic updates (EdDSA-signed appcast). The only third-party dependency.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "GrammarAI",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/GrammarAI",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("WebKit")]
        )
    ]
)
