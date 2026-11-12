// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HandwritingEraser",
    products: [
        .library(name: "HandwritingEraserKit", targets: ["HandwritingEraserKit"]),
        .executable(name: "HandwritingEraser", targets: ["HandwritingEraserApp"])
    ],
    targets: [
        .target(name: "HandwritingEraserKit"),
        .executableTarget(name: "HandwritingEraserApp", dependencies: ["HandwritingEraserKit"])
    ]
)
