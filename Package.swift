// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gobx",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GobxCore", targets: ["GobxCore"]),
        .executable(name: "gobx", targets: ["gobx-cli"]),
        .executable(name: "gobx-menubar", targets: ["gobx-menubar"])
    ],
    targets: [
        .target(
            name: "GobxCore",
            path: "Sources/gobx",
            resources: [
                .copy("Resources/selftest_golden.json"),
                .copy("Metal/PyramidProxy.metal")
            ]
        ),
        .executableTarget(
            name: "gobx-cli",
            dependencies: ["GobxCore"],
            path: "Sources/gobx-cli"
        ),
        .executableTarget(
            name: "gobx-menubar",
            dependencies: ["GobxCore"],
            path: "Sources/gobx-menubar",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
