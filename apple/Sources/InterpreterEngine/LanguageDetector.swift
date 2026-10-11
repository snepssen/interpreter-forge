import Foundation
import InterpreterCore
import NaturalLanguage

/// Which language a piece is in, from Apple's on-device recogniser: no model
/// to load, no time worth counting, and the same answer whichever translation
/// model is active. On the lines from the kitchen recording and the phone
/// tests it named 30 of 35; every miss was a two-word phrase ("Tak, tak",
/// "Igen") or garbled recognition, and it says how sure it is.
public struct LanguageDetector: Sendable {
    public struct Guess: Sendable, Equatable {
        public let code: String  // ISO 639-1, as Parakeet and TranslateGemma use
        public let confidence: Double
    }

    /// Europe's languages and its neighbours': what the people this is for speak.
    static let candidates: [NLLanguage] = Set(Languages.names.keys)
        .union(["no", "ca", "tr"]).sorted()
        .map { NLLanguage(rawValue: $0 == "no" ? "nb" : $0) }

    public init() {}

    public func guess(_ text: String) -> Guess? {
        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = Self.candidates
        recogniser.processString(text)
        guard let (language, confidence) = recogniser.languageHypotheses(withMaximum: 1).first else { return nil }
        let code = language == .norwegian ? "no" : language.rawValue  // Bokmål reports "nb"
        return Guess(code: code, confidence: confidence)
    }
}
