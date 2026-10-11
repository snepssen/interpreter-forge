import FluidAudio
import Foundation
import InterpreterCore
@preconcurrency import WhisperKit

/// One local recognizer at a time: Parakeet Ultra through FluidAudio, or the
/// recommended compressed Whisper large-v3 Turbo through WhisperKit. Both
/// return word times for the same bounded, repeatedly read audio windows.
public actor Recognizer {
    public let model: RecognitionModel
    private let manager: AsrManager?
    private let whisper: WhisperKit?
    /// Parakeet picks the language itself, and on short or noisy Polish it can
    /// write Russian. A hint in the expected languages' script keeps it out of
    /// the wrong alphabet at the source (FluidAudio's script-aware filtering).
    private var hint: Language?

    public static func load(model: RecognitionModel = .parakeetUltra, languages: [String],
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> Recognizer {
        if model == .whisper {
            let base = RecognitionStore.whisperBase
            try RecognitionStore.excludeFromBackup(base)
            let folder: URL
            if RecognitionStore.complete(in: base) {
                folder = RecognitionStore.whisperFolder
            } else {
                folder = try await WhisperKit.download(variant: RecognitionModel.whisperVariant,
                    downloadBase: base, progressCallback: { progress?($0.fractionCompleted) })
            }
            try Task.checkCancellation()
            progress?(1)
            let whisper = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path,
                tokenizerFolder: base, verbose: false, prewarm: true, load: true, download: false))
            try Task.checkCancellation()
            try RecognitionStore.markComplete(in: base)
            return Recognizer(model: model, whisper: whisper, languages: languages)
        }
        var handler: ProgressHandler?
        if let progress { handler = { progress($0.fractionCompleted) } }
        // Only download progress should be presented as downloading. FluidAudio's
        // load callback also reports fractions (including 50%) for cached models.
        let directory = try await AsrModels.download(version: .ultra, progressHandler: handler)
        progress?(1)
        let models = try await AsrModels.load(from: directory, version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return Recognizer(model: model, manager: manager, languages: languages)
    }

    private init(model: RecognitionModel, manager: AsrManager? = nil, whisper: WhisperKit? = nil, languages: [String]) {
        self.model = model
        self.manager = manager
        self.whisper = whisper
        hint = Self.hint(for: languages)
    }

    /// Only when the languages are restricted: with any language allowed,
    /// Russian is as welcome as Polish and no alphabet can be ruled out.
    public func setLanguages(_ languages: [String]) { hint = Self.hint(for: languages) }

    /// Only a script hint helps, so any expected language of the one script will do.
    static func hint(for languages: [String]) -> Language? {
        let hints = languages.filter { $0 != "en" }.compactMap(Language.init(rawValue:))
        return Set(hints.map(\.script)).count == 1 ? hints.first : nil
    }

    /// Words in `samples` (16 kHz mono), timed in stream seconds from `offset`.
    public func transcribe(_ samples: [Float], offset: Double) async throws -> [Word] {
        try Task.checkCancellation()
        guard samples.count >= 16_000 * 3 / 10 else { return [] }  // FluidAudio's minimum
        if let whisper {
            let options = DecodingOptions(task: .transcribe, temperatureFallbackCount: 0,
                detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 1)
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            try Task.checkCancellation()
            return Self.whisperWords(results.flatMap(\.segments).flatMap { $0.words ?? [] }, offset: offset,
                                     duration: Double(samples.count) / 16_000)
        }
        guard let manager else { throw Problem("Speech recognition is not loaded.") }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        return Self.words(result.tokenTimings ?? [], offset: offset)
    }


    /// Subword tokens joined into words: a word-boundary marker starts a new one.
    /// Punctuation is often stamped well into the silence after a word, so it
    /// adds to the text but not to the end time (as `asr.py`).
    static func words(_ tokens: [TokenTiming], offset: Double) -> [Word] {
        var words: [Word] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { words.append(Word(trimmed, offset + start, offset + end)) }
        }
        for token in tokens where !token.token.isEmpty && token.token != "<blank>" && token.token != "<pad>" {
            var piece = token.token.replacingOccurrences(of: "▁", with: " ")
            if piece.hasPrefix(" ") && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                text = ""
            }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                start = token.startTime
                end = token.startTime
                piece = piece.trimmingCharacters(in: .whitespaces)
            }
            text += piece
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { end = token.endTime }
        }
        flush()
        return words
    }
}
