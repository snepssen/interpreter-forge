import Foundation

/// Where the models and data live: in the app bundle when built by build.sh,
/// otherwise in this checkout and in voice-forge beside it, for development.
public enum Resources {
    static let checkout = URL(fileURLWithPath: #filePath)  // apple/Sources/InterpreterEngine/Resources.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let voiceForge = checkout.deletingLastPathComponent().appending(path: "voice-forge")
    static let voiceName = "en_US-snepssen-medium.onnx"

    public static var voice: URL? {
        first(bundled(voiceName),
              voiceForge.appending(path: "macos/Sources/VoiceForgeTTS/Resources/\(voiceName)"),
              voiceForge.appending(path: "cross-platform/resources/voices/\(voiceName)"))
    }

    public static var espeakData: URL? {
        first(bundled("espeak-ng-data"), voiceForge.appending(path: "macos/Sources/VoiceForgeTTS/Resources/espeak-ng-data"))
    }

    public static var vad: URL? { first(bundled("silero_vad.onnx"), checkout.appending(path: "models/silero_vad.onnx")) }

    private static func bundled(_ name: String) -> URL? { Bundle.main.resourceURL?.appending(path: name) }

    private static func first(_ candidates: URL?...) -> URL? {
        candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
