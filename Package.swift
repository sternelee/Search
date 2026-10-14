// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The one dependency the app carries: the A2UI renderer, for the
        // bot's cards. Data in, native controls out; no code from the model.
        // Pinned to a revision — the tagged releases sit on a pre-release
        // ICU package, which a stable version requirement can't reach.
        .package(url: "https://github.com/BBC6BAE9/a2ui-swift", revision: "4af5dda15dd050e091a80026b940cd41f8d5b93c"),
    ],
    targets: [
        .executableTarget(
            name: "Search",
            dependencies: [
                // A2UI, the agent-to-user interface protocol: the bot's cards
                // are the model's words drawn as native controls (see Bot.swift).
                .product(name: "A2UISwiftCore", package: "a2ui-swift"),
                .product(name: "A2UISwiftUI", package: "a2ui-swift"),
            ],
            path: "Sources/Search",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            path: "Tests/SearchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
