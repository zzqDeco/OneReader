// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OneReader",
    platforms: [
        .macOS("26.1")
    ],
    products: [
        .executable(name: "OneReader", targets: ["OneReader"])
    ],
    dependencies: [
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
        .executableTarget(
            name: "OneReader",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/OneReader"
        ),
        .testTarget(
            name: "OneReaderTests",
            dependencies: ["OneReader"],
            path: "Tests/OneReaderTests"
        )
    ]
)
