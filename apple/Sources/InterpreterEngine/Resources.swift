import Foundation
import ModelStore
import VoiceCore

/// Where the models and data live: in the app bundle when built by build.sh,
/// otherwise in this checkout and in voice-forge and voice-polyglot beside it,
/// for development.
public enum Resources {
    static let checkout = URL(fileURLWithPath: #filePath)  // apple/Sources/InterpreterEngine/Resources.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let voiceForge = checkout.deletingLastPathComponent().appending(path: "voice-forge")
    static let voicePolyglot = checkout.deletingLastPathComponent().appending(path: "voice-polyglot")

    /// Where translation models are read from.
    ///
    /// Debug keeps Application Support/Interpreter/Models, then this checkout's
    /// models/. A Release build reads only `ModelStore.sharedRoot()` — on a
    /// Mac, ~/Library/Application Support/snepssen/models — and never
    /// downloads, moves, or deletes. `release(at:)` is what makes that store
    /// read-only; the app's own DEBUG flag chooses it, because a package
    /// cannot see that flag.
    #if DEBUG
    public static let models = ModelStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Interpreter/Models"),
        alsoSearching: [checkout.appending(path: "models")],
        leaveLinks: false)
    #else
    private static let releaseModels: (store: ModelStore, failure: String?) = {
        do { return (ModelStore.release(at: try ModelStore.sharedRoot()), nil) } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (ModelStore.release(at: URL(fileURLWithPath: "/")), message)
        }
    }()
    public static var models: ModelStore { releaseModels.store }
    /// Set when the shared folder cannot be opened, naming where it should be.
    public static var modelsUnavailable: String? { releaseModels.failure }
    #endif
    static let voiceName = "en_US-snepssen-medium.onnx"
    static let polyglotName = "snepssen-polyglot.onnx"

    /// The polyglot snepssen, which speaks every language offered; failing
    /// that, voice-forge's English one.
    public static var voice: URL? { polyglotVoice ?? englishVoice }

    /// Bundled under one name; in development, voice-polyglot's newest export
    /// (`work/runs/polyglot/exports/epoch-NNN/`) where it is trained, else the
    /// latest release that `scripts/polyglot-voice.sh` fetched into models/voice.
    public static var polyglotVoice: URL? {
        first(bundled(polyglotName), newestExport(in: voicePolyglot.appending(path: "work/runs/polyglot/exports")),
              checkout.appending(path: "models/voice/\(polyglotName)"))
    }

    static func newestExport(in folder: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let epochs = names.filter { $0.wholeMatch(of: /epoch-\d+/) != nil }.sorted()
        for name in epochs.reversed() {
            let model = folder.appending(path: "\(name)/snepssen-polyglot-\(name).onnx")
            if FileManager.default.fileExists(atPath: model.path) { return model }
        }
        return nil
    }

    public static var englishVoice: URL? {
        first(bundled(voiceName),
              voiceForge.appending(path: "macos/Sources/VoiceForgeTTS/Resources/\(voiceName)"),
              voiceForge.appending(path: "cross-platform/resources/voices/\(voiceName)"))
    }

    /// voice-core's, the data every snepssen voice was trained with, from its
    /// resource bundle.
    public static var espeakData: URL? { EspeakData.directory }

    public static var vad: URL? { first(bundled("silero_vad.onnx"), checkout.appending(path: "models/silero_vad.onnx")) }

    private static func bundled(_ name: String) -> URL? { Bundle.main.resourceURL?.appending(path: name) }

    private static func first(_ candidates: URL?...) -> URL? {
        candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
