// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AitvarasKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AitvarasCore", targets: ["AitvarasCore"]),
        .library(name: "AitvarasStore", targets: ["AitvarasStore"]),
        .library(name: "AitvarasEngines", targets: ["AitvarasEngines"]),
        .library(name: "AitvarasRAG", targets: ["AitvarasRAG"]),
        .library(name: "AitvarasConnectors", targets: ["AitvarasConnectors"]),
        .library(name: "AitvarasVoice", targets: ["AitvarasVoice"]),
        .library(name: "AitvarasAgent", targets: ["AitvarasAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3")
    ],
    targets: [
        .target(name: "AitvarasCore"),
        .target(
            name: "AitvarasStore",
            dependencies: [
                "AitvarasCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "AitvarasEngines",
            dependencies: [
                "AitvarasCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .target(name: "AitvarasRAG", dependencies: ["AitvarasCore", "AitvarasStore"]),
        .target(name: "AitvarasConnectors", dependencies: ["AitvarasCore", "AitvarasStore"]),
        .target(name: "AitvarasVoice", dependencies: ["AitvarasCore"]),
        .target(
            name: "AitvarasAgent",
            dependencies: ["AitvarasCore", "AitvarasStore", "AitvarasEngines", "AitvarasRAG", "AitvarasConnectors"]
        ),
        .testTarget(
            name: "AitvarasCoreTests",
            dependencies: ["AitvarasCore", "AitvarasStore", "AitvarasRAG", "AitvarasConnectors", "AitvarasAgent", "AitvarasEngines", "AitvarasVoice"]
        )
    ]
)
