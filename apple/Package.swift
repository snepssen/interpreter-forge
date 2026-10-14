// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Interpreter",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // For the iPhone app's Xcode project.
        .library(name: "InterpreterEngine", targets: ["InterpreterEngine"]),
        .library(name: "InterpreterCore", targets: ["InterpreterCore"]),
        .library(name: "InterpreterUI", targets: ["InterpreterUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        .testTarget(name: "InterpreterEngineTests", dependencies: [
            "InterpreterEngine", "InterpreterCore",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        // Everything that can be decided without a model: the segmenter, clock
        // times, language evidence, echoes, catch-up. Held to the Python
        // implementation by `tccheck`.
        .target(name: "InterpreterCore"),
        // Never links a model; `swift run tccheck` stays fast and runs anywhere.
        .executableTarget(name: "tccheck", dependencies: ["InterpreterCore"]),
        // espeak-ng at piper1-gpl's commit, for macOS, iOS and the simulator
        // (scripts/build-espeak.sh); phonemes identical to voice-forge's library.
        .binaryTarget(name: "CEspeakNG", path: "Frameworks/CEspeakNG.xcframework"),
        // NSException to NSError, for AVAudioEngine, which raises instead of throwing.
        .target(name: "ObjCExceptions"),
        // The models and the live loop: Parakeet and VAD (FluidAudio, ONNX),
        // the translation model (MLX), the voice (Piper on ONNX).
        .target(name: "InterpreterEngine", dependencies: [
            "InterpreterCore", "CEspeakNG", "ObjCExceptions",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ]),
        // The views, shared by the Mac app and the iPhone app.
        .target(name: "InterpreterUI", dependencies: ["InterpreterCore", "InterpreterEngine"]),
        .executableTarget(name: "Interpreter", dependencies: ["InterpreterEngine", "InterpreterUI"]),
        // Test speech in the app's own voice, for tcrun to interpret.
        .executableTarget(name: "tcsay", dependencies: ["InterpreterEngine"]),
        // A recording through the live pipeline in real time, for measuring.
        .executableTarget(name: "tcrun", dependencies: [
            "InterpreterCore", "InterpreterEngine", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
    ]
)
