import Foundation
import XCTest
@testable import InterpreterEngine
import VoiceCore

/// The voice on voice-core: Polyphon's id parity with voice-polyglot's Python
/// is voice-core's own test; here, that the app's voice speaks through it.
final class VoiceTests: XCTestCase {
    private func polyglot() throws -> Voice {
        guard let model = Resources.polyglotVoice, let data = Resources.espeakData else {
            throw XCTSkip("No polyglot voice (voice-polyglot beside translate-core, or models/voice).")
        }
        return try Voice(model: model, espeakData: data)
    }

    func testEveryTrainedLanguageGoesThroughPolyphon() throws {
        let voice = try polyglot()
        XCTAssertTrue(voice.isPolyglot)
        XCTAssertEqual(Set(voice.languages), Set(Polyphon.trained))
        // German r is uvular, a symbol only Polyphon gives it.
        let ids = try voice.polyglotIDs("Rot.", language: "de")
        let espeak = try EspeakPhonemizer(dataDirectory: XCTUnwrap(Resources.espeakData), voice: "de")
        XCTAssertTrue(try Polyphon.sentences("Rot.", language: "de", espeak: espeak)[0].contains("\u{281}"))
        XCTAssertGreaterThan(ids.count, 6)
    }

    func testEachLanguageSpeaksAtItsOwnPace() throws {
        let voice = try polyglot()
        voice.language = "de"
        let german = try voice.speak("Treffen sich zwei Jäger. Beide tot.")
        XCTAssertGreaterThan(Double(german.count) / voice.sampleRate, 2)
    }
}
