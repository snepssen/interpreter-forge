import FluidAudio
import Foundation
import InterpreterCore

/// Parakeet TDT v3 through FluidAudio, on the Neural Engine: 75-161 ms for a
/// 2-15 s window on an M1, against 300-800 ms through MLX in Python, and off
/// the GPU the translation model needs.
public actor Recognizer {
    private let manager: AsrManager
    /// Parakeet picks the language itself, and on short or noisy Polish it can
    /// write Russian. A hint in the expected languages' script keeps it out of
    /// the wrong alphabet at the source (FluidAudio's script-aware filtering).
    private var hint: Language?

    public static func load(languages: [String], progress: (@Sendable (Double) -> Void)? = nil) async throws -> Recognizer {
        var handler: ProgressHandler?
        if let progress { handler = { progress($0.fractionCompleted) } }
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return Recognizer(manager: manager, languages: languages)
    }

    private init(manager: AsrManager, languages: [String]) {
        self.manager = manager
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
        guard samples.count >= 16_000 * 3 / 10 else { return [] }  // FluidAudio's minimum
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
