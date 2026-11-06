// swift-tools-version: 6.2
// Linked only by the embedded InferenceService XPC target. The host app never links MLX (§4.1, §14.3).
import PackageDescription

let package = Package(
    name: "InferenceEngines",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "InferenceEngines", targets: ["InferenceEngines"]),
        .executable(name: "inference-bench", targets: ["inference-bench"]),
    ],
    dependencies: [
        // Exact pins from spec §2.2. mlx-audio-swift 0.1.7 is the version whose MLX range overlaps mlx-swift-lm 3.32.3.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/Neywa-Labs/mlx-audio-swift.git", exact: "0.1.7"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", "1.1.6"..<"2.0.0"),
    ],
    targets: [
        .target(
            name: "InferenceEngines",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        // Developer measurement tool (§A3, §A4, §A8). Not shipped in the app bundle.
        .executableTarget(name: "inference-bench", dependencies: ["InferenceEngines"]),
    ]
)
