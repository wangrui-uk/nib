// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GrammarAI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GrammarAI",
            path: "Sources/GrammarAI",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("WebKit")]
        )
    ]
)
