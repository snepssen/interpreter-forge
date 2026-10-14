import Foundation
import XCTest
@testable import InterpreterEngine

/// Polyphon against voice-polyglot's Python, id for id: the voice only makes
/// the sounds it learned under the symbols it learned them as.
final class PolyphonTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/polyphon_ids.tsv")

    func testIdsMatchTheTrainingPhonemizer() throws {
        guard let model = Resources.polyglotVoice, let data = Resources.espeakData else {
            throw XCTSkip("No polyglot voice (voice-polyglot beside translate-core) or espeak-ng data.")
        }
        let voice = try Voice(model: model, espeakData: data)
        XCTAssertTrue(voice.isPolyglot)
        var checked = 0
        for line in try String(contentsOf: Self.fixtures, encoding: .utf8).split(separator: "\n")
        where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let expected = fields[2].split(separator: " ").compactMap { Int($0) }
            let got = try voice.polyglotIDs(fields[1], language: fields[0])
            XCTAssertEqual(got, expected, "[\(fields[0])] \(fields[1])")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30)
    }

    func testEachLanguageSpeaksAtItsOwnPace() throws {
        guard let model = Resources.polyglotVoice, let data = Resources.espeakData else {
            throw XCTSkip("No polyglot voice or espeak-ng data.")
        }
        let voice = try Voice(model: model, espeakData: data)
        XCTAssertEqual(Set(voice.languages), Set(Polyphon.trained))
        voice.language = "de"
        let german = try voice.speak("Treffen sich zwei Jäger. Beide tot.")
        XCTAssertGreaterThan(Double(german.count) / voice.sampleRate, 2)
    }
}
