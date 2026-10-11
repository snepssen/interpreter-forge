import Foundation
import InterpreterCore
import WhisperKit

extension Recognizer {
    /// Word timestamps are relative to each re-read window, not to the session.
    static func whisperWords(_ tokens: [WordTiming], offset: Double, duration: Double) -> [Word] {
        tokens.compactMap { token in
            let text = token.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, token.start.isFinite, token.end.isFinite,
                  token.end >= token.start, Double(token.start) < duration else { return nil }
            let start = max(0, Double(token.start))
            let end = min(duration, max(start, Double(token.end)))
            return Word(text, offset + start, offset + end)
        }
    }
}
