import Foundation
import InterpreterCore
import WhisperKit

/// Recognition is independent of the translation model. Only one is loaded.
public enum RecognitionModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetUltra = "parakeet-ultra"
    case whisper = "whisper-large-v3-v20240930-626mb"

    public var id: String { rawValue }
    public var name: String { self == .parakeetUltra ? "Parakeet Ultra" : "Whisper large-v3 Turbo" }
    public static let whisperVariant = "large-v3-v20240930_626MB"
    public var download: Int64 { self == .parakeetUltra ? 630_000_000 : 626_000_000 }
    public var summary: String {
        self == .parakeetUltra
            ? "Fast recognition in 25 European languages. Updated Parakeet weights; runs on the Neural Engine."
            : "100 languages, Norwegian among them, for speech outside Parakeet's 25. Much slower: about ten times Parakeet's time per window on an M1 Mac, so more delay."
    }
    public var tagline: String { self == .parakeetUltra ? "25 languages · fast" : "100 languages · slower" }
    public var languageNames: [String: String] {
        if self == .parakeetUltra { return Languages.names }
        let locale = Locale(identifier: "en")
        return Dictionary(uniqueKeysWithValues: Constants.languageCodes.sorted().map { code in
            (code, Languages.names[code] ?? locale.localizedString(forLanguageCode: code)
                ?? Constants.languages.keys.sorted().first { Constants.languages[$0] == code }!.capitalized)
        })
    }
    /// The codes it can hear, and `target`, the listener's language, which
    /// the filter always holds.
    public func supportedFilter(_ codes: [String], keeping target: String = "en") -> [String] {
        let supported = codes.filter { languageNames[$0] != nil && $0 != target }
        return [target] + supported
    }
}
