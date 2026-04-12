// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MLXHub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MLXHub",
            targets: ["MLXHub"]
        )
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "MLXHub",
            dependencies: [],
            path: "MLXHub",
            resources: [
                .copy("Resources/python_bridge.py"),
                .copy("Resources/runtime")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
