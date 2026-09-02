// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OneReader",
    platforms: [
        .macOS("26.1"),
        .iOS("26.1")
    ],
    products: [
        .library(name: "OneReader", targets: ["OneReader"]),
        .executable(name: "OneReaderApp", targets: ["OneReaderApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/SwiftAgent.git",
            exact: "2.0.1",
            traits: ["OpenFoundationModels"]
        ),
        .package(
            url: "https://github.com/1amageek/AnyFoundationModels.git",
            exact: "0.5.5",
            traits: ["Claude", "Response", "Ollama"]
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.10.0"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            exact: "2.13.9"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            exact: "0.8.0"
        )
    ],
    targets: [
        .target(
            name: "OneReader",
            dependencies: [
                .product(name: "SwiftAgent", package: "SwiftAgent"),
                .product(name: "ClaudeFoundationModels", package: "AnyFoundationModels"),
                .product(name: "ResponseFoundationModels", package: "AnyFoundationModels"),
                .product(name: "OllamaFoundationModels", package: "AnyFoundationModels"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/OneReader"
        ),
        .executableTarget(
            name: "OneReaderApp",
            dependencies: ["OneReader"],
            path: "Apps/OneReaderApp"
        ),
        .testTarget(
            name: "OneReaderTests",
            dependencies: [
                "OneReader",
                .product(name: "SwiftAgent", package: "SwiftAgent"),
            ],
            path: "Tests/OneReaderTests"
        )
    ]
)
