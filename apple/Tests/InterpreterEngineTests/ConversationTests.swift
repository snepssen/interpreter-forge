import Foundation
import InterpreterCore
import SampleBuffer
import XCTest
@testable import InterpreterEngine

/// Two-way conversation: exactly one language spoken here beside the
/// listener's, each side interpreted into the other's, with no stopping.
final class ConversationTests: XCTestCase {
    private let polish = Conversation(spoken: ["pl"], target: "en")!

    func testOnlyOneLanguageBesideTheListenersMakesAConversation() {
        XCTAssertNil(Conversation(spoken: [], target: "en"), "any language stays one way")
        XCTAssertNil(Conversation(spoken: ["pl", "hu"], target: "en"), "several stay one way")
        XCTAssertNil(Conversation(spoken: ["en"], target: "en"))
        let conversation = Conversation(spoken: ["en", "pl"], target: "en")  // the marker is ignored
        XCTAssertEqual(conversation?.guest, "pl")
        XCTAssertEqual(conversation?.host, "en")
        XCTAssertEqual(conversation?.other("pl"), "en")
        XCTAssertEqual(conversation?.other("en"), "pl")
    }

    /// Echo cancellation follows the mode: on both ways round, off one way.
    @MainActor func testEchoCancellationIsAskedForOnlyInAConversation() {
        let session = LiveSession()
        let (languages, target) = (session.languages, session.target)
        defer { session.target = target; session.languages = languages }
        session.target = "en"
        session.languages = ["en", "pl"]
        XCTAssertNotNil(session.conversation)
        XCTAssertTrue(session.echoCancellation)
        session.languages = ["en", "pl", "hu"]
        XCTAssertNil(session.conversation)
        XCTAssertFalse(session.echoCancellation)
        session.languages = ["en"]
        XCTAssertFalse(session.echoCancellation)
    }

    func testTheTextsOwnSignsComeFirst() {
        // Polish letters or everyday words: the guest, whatever the detector says.
        XCTAssertEqual(polish.source(of: "Właśnie tak", guess: ("en", 0.9), last: "en"), "pl")
        XCTAssertEqual(polish.source(of: "nie wiem", guess: ("en", 0.9), last: "en"), "pl")
        // A script rules a side out.
        let russian = Conversation(spoken: ["ru"], target: "en")!
        XCTAssertEqual(russian.source(of: "Где вокзал?", guess: nil, last: "en"), "ru")
        XCTAssertEqual(russian.source(of: "Where is the station?", guess: nil, last: "ru"), "en")
        // Letters of a third language rule out the side that has none.
        let hungarian = Conversation(spoken: ["hu"], target: "de")!
        XCTAssertEqual(hungarian.source(of: "Die Straße", guess: ("hu", 0.9), last: nil), "de")
    }

    func testTheDetectorThenTheSideThatSpokeLast() {
        XCTAssertEqual(polish.source(of: "Okay then", guess: ("en", 0.9), last: "pl"), "en")
        XCTAssertEqual(polish.source(of: "Dobry", guess: ("pl", 0.7), last: "en"), "pl")
        // A near coin toss: the same side is still speaking.
        XCTAssertEqual(polish.source(of: "Okay", guess: ("pl", 0.55), last: "en"), "en")
        XCTAssertEqual(polish.source(of: "Okay", guess: ("en", 0.55), last: "pl"), "pl")
        // Nobody has spoken yet: the best guess, else the guest.
        XCTAssertEqual(polish.source(of: "Okay", guess: ("en", 0.55), last: nil), "en")
        XCTAssertEqual(polish.source(of: "Okay", guess: nil, last: nil), "pl")
        // A guess outside the two counts for nothing.
        XCTAssertEqual(polish.source(of: "Okay", guess: ("fr", 0.99), last: "en"), "en")
    }

    /// Apple's detector, held to the two, on ordinary turns of a conversation.
    func testEachTurnFindsItsSideWithTheRealDetector() {
        let detector = LanguageDetector()
        let cases: [(Conversation, String, String)] = [
            (polish, "Dzień dobry, czy mogę zamówić kawę?", "pl"),
            (polish, "Good morning, what would you like to drink?", "en"),
            (polish, "Poproszę dużą kawę z mlekiem.", "pl"),
            (polish, "Of course, that will be five euros.", "en"),
            (Conversation(spoken: ["hu"], target: "en")!, "Hol van a vasútállomás?", "hu"),
            (Conversation(spoken: ["hu"], target: "en")!, "It is just around the corner.", "en"),
            (Conversation(spoken: ["de"], target: "en")!, "Wann fährt der nächste Zug nach Berlin?", "de"),
            (Conversation(spoken: ["de"], target: "en")!, "The next train leaves at half past ten.", "en"),
            (Conversation(spoken: ["en"], target: "pl")!, "Thank you very much for your help.", "en"),
            (Conversation(spoken: ["en"], target: "pl")!, "Nie ma za co, miłego dnia!", "pl"),
        ]
        var last: String?
        for (conversation, text, expected) in cases {
            let guess = detector.guess(text, languages: conversation.languages)
            let side = conversation.source(of: text, guess: guess.map { ($0.code, $0.confidence) }, last: last)
            XCTAssertEqual(side, expected, text)
            last = side
        }
    }

    func testTheVoiceComingBackIsRecognisedOnlyWhileItPlays() {
        var echoes = SpokenEchoes()
        XCTAssertFalse(echoes.heard("Dzień dobry", from: 1, to: 2))
        echoes.said("Dzień dobry, czym mogę służyć?", from: 10, to: 12)
        XCTAssertTrue(echoes.heard("dzień dobry czym mogę", from: 10.2, to: 11.5), "while it plays")
        XCTAssertTrue(echoes.heard("służyć", from: 12.4, to: 13), "the room rings on")
        XCTAssertTrue(echoes.heard("Dzień dobry", from: 9.6, to: 10.1), "the stream clock runs early")
        XCTAssertFalse(echoes.heard("Dzień dobry", from: 20, to: 21), "said again later: a person")
        XCTAssertFalse(echoes.heard("Poproszę dużą kawę", from: 10.5, to: 11.5), "someone else, over it")
        XCTAssertFalse(echoes.heard("...", from: 10.5, to: 11.5))
        for i in 0..<10 { echoes.said("piece \(i)", from: 100 + Double(i), to: 100.5 + Double(i)) }
        XCTAssertFalse(echoes.heard("Dzień dobry czym mogę", from: 10.2, to: 11.5), "only the last few are kept")
    }

    func testRunsSplitWhereTheSideChanges() {
        func piece(_ index: Int, _ direction: Direction?) -> (segment: Segment, direction: Direction?) {
            (Segment(index: index, words: [Word("w\(index)", Double(index), Double(index) + 0.5)],
                     reason: "pause", decidedAt: 0), direction)
        }
        let toEnglish = Direction(from: "pl", into: "en")
        let runs = Pipeline.runs([piece(0, toEnglish), piece(1, toEnglish), piece(2, toEnglish.reversed),
                                  piece(3, toEnglish)])
        XCTAssertEqual(runs.map { $0.segments.map(\.index) }, [[0, 1], [2], [3]])
        XCTAssertEqual(runs.map(\.direction), [toEnglish, toEnglish.reversed, toEnglish])
        // One way round nothing changes: everything waiting goes as one.
        XCTAssertEqual(Pipeline.runs([piece(0, nil), piece(1, nil), piece(2, nil)]).map { $0.segments.count }, [3])
    }

    func testEachSideIsSpokenInTheOthersLanguage() async throws {
        let (events, voice) = try await run(TwoWayLinguist(heard: "Dzień dobry wszystkim.",
                                                           direction: Direction(from: "pl", into: "en")))
        XCTAssertEqual(events.interpreted.map(\.into), ["en"])
        XCTAssertEqual(events.interpreted.map(\.translation), ["Hello everyone."])
        XCTAssertEqual(voice.languages, ["en"])
    }

    /// Detected as the guest but really the listener: translated "into" its
    /// own language it comes back unchanged, and goes the other way instead.
    func testAPieceThatEchoesGoesTheOtherWayRoundOnce() async throws {
        let linguist = TwoWayLinguist(heard: "Good morning everyone.", direction: Direction(from: "pl", into: "en"))
        let (events, voice) = try await run(linguist)
        XCTAssertEqual(events.interpreted.map(\.into), ["pl"])
        XCTAssertEqual(events.interpreted.map(\.translation), ["Dzień dobry wszystkim."])
        XCTAssertEqual(voice.languages, ["pl"])
        let asked = await linguist.asked
        XCTAssertEqual(asked, ["en", "pl"])
    }

    func testOneWayRoundTheEventNamesNoLanguage() async throws {
        let (events, voice) = try await run(TwoWayLinguist(heard: "Dzień dobry wszystkim.", direction: nil))
        XCTAssertEqual(events.interpreted.count, 1)
        XCTAssertNil(events.interpreted.first?.into)
        XCTAssertEqual(voice.languages, [nil])
    }

    private func run(_ linguist: TwoWayLinguist) async throws -> (Captured, RecordingVoice) {
        let events = Captured()
        let voice = RecordingVoice()
        let pipeline = Pipeline(recognition: WordsRecognizer(text: linguist.heard), translation: linguist,
                                synthesis: voice, makeVAD: { AlwaysSpeech() })
        try pipeline.start(source: OneSecond(), speaker: nil, audible: false) { events.append($0) }
        let finished = expectation(description: "finishes")
        Task { await pipeline.finish(); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        pipeline.stop()
        XCTAssertNil(pipeline.failure)
        return (events, voice)
    }
}

/// Translates between Polish and English by lookup; English "into" English
/// comes back as it went in, as a real model repeats a piece already in the
/// language it is asked for.
private actor TwoWayLinguist: SpeechInterpreting {
    nonisolated let model = ModelCatalog.translation[0]
    nonisolated let heard: String
    let detected: Direction?
    private(set) var asked: [String] = []
    private let polish = ["Dzień dobry wszystkim.": "Hello everyone.", "Good morning everyone.": "Dzień dobry wszystkim."]

    init(heard: String, direction: Direction?) {
        self.heard = heard
        detected = direction
    }
    func complete(_ text: String) -> Bool { true }
    func gate(_ text: String) -> Silence? { nil }
    func remember(_ text: String) {}
    func translate(_ text: String, brief: Bool) -> String { polish[text] ?? text }
    func direction(_ text: String) -> Direction? { detected }
    func translate(_ text: String, brief: Bool, direction: Direction?) -> String {
        guard let direction else { return translate(text, brief: brief) }
        asked.append(direction.into)
        let isEnglish = text.hasPrefix("Good")
        return (direction.into == "en") == isEnglish ? text : (polish[text] ?? text)
    }
}

private final class RecordingVoice: SpeechSynthesizing, @unchecked Sendable {
    let sampleRate = 16_000.0
    private let lock = NSLock()
    private var spoken: [String?] = []
    var languages: [String?] { lock.withLock { spoken } }
    func speak(_ text: String, pace: Double) throws -> [Float] { try speak(text, pace: pace, language: nil) }
    func speak(_ text: String, pace: Double, language: String?) throws -> [Float] {
        lock.withLock { spoken.append(language) }
        return [Float](repeating: 0.1, count: 1_600)
    }
}

private struct WordsRecognizer: SpeechRecognizing {
    let text: String
    func transcribe(_ samples: [Float], offset: Double) async throws -> [Word] {
        text.split(separator: " ").enumerated().map { i, word in
            Word(String(word), Double(i) * 0.3, Double(i) * 0.3 + 0.3)
        }
    }
}

private final class AlwaysSpeech: SpeechDetecting, @unchecked Sendable {
    var lastSpeech = 1.0
    func push(_ frame: ArraySlice<Float>, at: Double) throws -> Bool { true }
    func silence(at: Double) -> Double { 0.6 }
}

private final class OneSecond: AudioSource, @unchecked Sendable {
    let buffer = SampleBuffer()
    let finished = true
    func start() { buffer.append([Float](repeating: 0, count: 16_000)) }
    func stop() {}
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PipelineEvent] = []
    func append(_ event: PipelineEvent) { lock.withLock { items.append(event) } }
    var interpreted: [(translation: String, into: String?)] {
        lock.withLock {
            items.compactMap {
                if case .interpreted(_, let translation, _, _, _, _, let into) = $0 { (translation, into) } else { nil }
            }
        }
    }
}
