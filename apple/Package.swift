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
        // Hearing shared with companion-forge. ObjCExceptions (0.1.0) turns
        // AVAudioEngine's NSException into an NSError. SileroVAD (0.2.0) is the
        // v5 detector; the weights stay in the app as silero_vad.onnx. ONNX
        // Runtime comes with this package and with voice-core.
        .package(url: "https://github.com/snepssen/speech-core", from: "0.2.0"),
        // The speech engine Voice Forge and Gateway Forge share: espeak-ng and
        // its data, the phonemizer, Polyphon and Piper inference. Bumped by
        // voice-core's release script, which runs these checks first.
        .package(url: "https://github.com/snepssen/voice-core", from: "1.0.0"),
    ],
    targets: [
        .testTarget(name: "InterpreterEngineTests", dependencies: [
            "InterpreterEngine", "InterpreterCore",
            .product(name: "SileroVAD", package: "speech-core"),
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        // Everything that can be decided without a model: the segmenter, clock
        // times, language evidence, echoes, catch-up. Held to the Python
        // implementation by `tccheck`.
        .target(name: "InterpreterCore"),
        // Never links a model; `swift run tccheck` stays fast and runs anywhere.
        .executableTarget(name: "tccheck", dependencies: ["InterpreterCore"]),
        // The models and the live loop: Parakeet (FluidAudio), Silero VAD
        // (speech-core), the translation model (MLX), the voice (voice-core's
        // Piper on ONNX).
        .target(name: "InterpreterEngine", dependencies: [
            "InterpreterCore",
            .product(name: "ObjCExceptions", package: "speech-core"),
            .product(name: "SileroVAD", package: "speech-core"),
            .product(name: "VoiceCore", package: "voice-core"),
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // The views, shared by the Mac app and the iPhone app.
        .target(name: "InterpreterUI", dependencies: ["InterpreterCore", "InterpreterEngine"]),
        .executableTarget(name: "Interpreter", dependencies: ["InterpreterEngine", "InterpreterUI"]),
        // Test speech in the app's own voice, for tcrun to interpret.
        .executableTarget(name: "tcsay", dependencies: ["InterpreterEngine"]),
        // Recognition only: JSON evidence, without translation or playback.
        .executableTarget(name: "tcasr", dependencies: ["InterpreterEngine"]),
        // A recording through the live pipeline in real time, for measuring.
        .executableTarget(name: "tcrun", dependencies: [
            "InterpreterCore", "InterpreterEngine", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
    ]
)
