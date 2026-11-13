// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HandwritingEraser",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HandwritingEraserKit", targets: ["HandwritingEraserKit"]),
        .executable(name: "HandwritingEraser", targets: ["HandwritingEraserApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")
    ],
    targets: [
        .target(name: "HandwritingEraserKit", dependencies: [
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
        ]),
        .executableTarget(name: "HandwritingEraserApp", dependencies: ["HandwritingEraserKit"]),
        .testTarget(name: "HandwritingEraserKitTests", dependencies: ["HandwritingEraserKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HandwritingEraserAppTests", dependencies: ["HandwritingEraserApp", "HandwritingEraserKit"])
    ]
)
