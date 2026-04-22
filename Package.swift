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
            exclude: [
                "Resources/Info.plist",
                "Resources/__pycache__"
            ],
            resources: [
                .copy("Resources/bridge_utils.py"),
                .copy("Resources/python_bridge.py"),
                .copy("Resources/acestep_bridge.py"),
                .copy("Resources/runtime")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MLXHubTests",
            dependencies: ["MLXHub"],
            path: "Tests/MLXHubTests"
        )
    ]
)
