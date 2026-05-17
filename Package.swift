// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let targetRoot = packageRoot.appendingPathComponent("MLXtra")
let generatedResourceExcludes = [
    "Resources/__pycache__"
].filter {
    FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent($0).path)
}

let package = Package(
    name: "MLXtra",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MLXtra",
            targets: ["MLXtra"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.7.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "MLXtra",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "MLXtra",
            exclude: [
                "Resources/Info.plist",
                "Resources/Assets.xcassets"
            ] + generatedResourceExcludes,
            resources: [
                .copy("Resources/bridge_utils.py"),
                .copy("Resources/python_bridge.py"),
                .copy("Resources/acestep_bridge.py"),
                .copy("Resources/model-catalog.json"),
                .copy("Resources/stable-channel.json"),
                .copy("Resources/runtime")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MLXtraTests",
            dependencies: ["MLXtra"],
            path: "Tests/MLXtraTests"
        )
    ]
)
