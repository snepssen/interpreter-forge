// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Interpreter",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
    ],
    targets: [
        // Everything that can be decided without a model: the segmenter, clock
        // times, language evidence, echoes, catch-up. Held to the Python
        // implementation by `tccheck`.
        .target(name: "InterpreterCore"),
        // Never links a model; `swift run tccheck` stays fast and runs anywhere.
        .executableTarget(name: "tccheck", dependencies: ["InterpreterCore"]),
        .executableTarget(name: "spike", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
    ]
)
