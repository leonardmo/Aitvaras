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
        .library(name: "AitvarasAgent", targets: ["AitvarasAgent"]),
        .library(name: "AitvarasAgents", targets: ["AitvarasAgents"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Declared here as well as in project.yml so `swift test` and the
        // generated app project share one stable Package.resolved graph.
        .package(url: "https://github.com/warrenm/GLTFKit2", from: "0.5.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        // Pinned before the upstream MLX 0.32 migration; shares our 0.31 graph.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", revision: "8d86630ade569728aaea3dc1a29fc44e2efa719b")
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
        .target(name: "AitvarasAgents", dependencies: ["AitvarasCore"]),
        .target(
            name: "AitvarasConnectors",
            dependencies: ["AitvarasCore", "AitvarasStore"],
            resources: [.process("Resources")]
        ),
        .target(name: "AitvarasVoice", dependencies: [
            "AitvarasCore",
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift")
        ]),
        .target(
            name: "AitvarasAgent",
            dependencies: ["AitvarasCore", "AitvarasStore", "AitvarasEngines", "AitvarasRAG", "AitvarasConnectors"]
        ),
        .testTarget(
            name: "AitvarasCoreTests",
            dependencies: [
                "AitvarasCore", "AitvarasStore", "AitvarasRAG",
                "AitvarasConnectors", "AitvarasAgent", "AitvarasEngines",
                "AitvarasVoice", "AitvarasAgents",
                // Keeps the package and generated-app dependency graphs in
                // lockstep; avatar rendering itself remains in the app target.
                .product(name: "GLTFKit2", package: "GLTFKit2")
            ]
        )
    ]
)
