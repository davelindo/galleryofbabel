// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gobx",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "gobx", targets: ["gobx"])
    ],
    targets: [
        .executableTarget(
            name: "gobx",
            path: "Sources/gobx",
            resources: [
                .copy("Resources/selftest_golden.json")
            ]
        )
    ]
)
