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
        )
    ],
    targets: [
        .executableTarget(
            name: "OneReader",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
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
