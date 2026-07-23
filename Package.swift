// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OneReader",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OneReader", targets: ["OneReader"])
    ],
    targets: [
        .executableTarget(
            name: "OneReader",
            path: "Sources/OneReader"
        ),
        .testTarget(
            name: "OneReaderTests",
            dependencies: ["OneReader"],
            path: "Tests/OneReaderTests"
        )
    ]
)

