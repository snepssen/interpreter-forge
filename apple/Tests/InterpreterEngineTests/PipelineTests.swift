import Foundation
import InterpreterCore
import SampleBuffer
import XCTest
@testable import InterpreterEngine

final class PipelineTests: XCTestCase {
    func testStageFailuresStopCaptureAndFinish() async throws {
        for stage in [Fault.vad, .recognition, .translation, .voice] {
            let source = TestSource()
            let events = CapturedEvents()
            let pipeline = makePipeline(stage)
            try pipeline.start(source: source, speaker: nil, audible: false) { events.append($0) }
            let finished = expectation(description: "\(stage) finishes after failure")
            Task { await pipeline.finish(); finished.fulfill() }
            await fulfillment(of: [finished], timeout: 3)
            pipeline.stop()
            XCTAssertTrue(source.stopped)
            XCTAssertNotNil(pipeline.failure)
            XCTAssertEqual(events.failures.count, 1)
            XCTAssertTrue(pipeline.speaker?.placed.isEmpty == true)
        }
    }

    func testJudgeFailureStopsInsteadOfAcceptingIncompleteSpeech() async throws {
        let source = TestSource(finished: false)
        let events = CapturedEvents()
        let pipeline = makePipeline(.judge)
        try pipeline.start(source: source, speaker: nil, audible: false) { events.append($0) }
        // The second pass agrees with the first, so the segmenter asks the judge.
        try await Task.sleep(for: .milliseconds(100))
        source.buffer.append([Float](repeating: 0, count: 16_000))
        let finished = expectation(description: "judge failure finishes")
        Task { await pipeline.finish(); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        pipeline.stop()
        XCTAssertTrue(source.stopped)
        XCTAssertTrue(pipeline.failure?.contains("Checking speech") == true)
        XCTAssertEqual(events.failures.count, 1)
    }

    func testUnclearTranslationIsShownWithoutStoppingOrSpeaking() async throws {
        let events = CapturedEvents()
        let pipeline = makePipeline(.unclear)
        try pipeline.start(source: TestSource(), speaker: nil, audible: false) { events.append($0) }
        let finished = expectation(description: "clarification finishes")
        Task { await pipeline.finish(); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(pipeline.failure)
        XCTAssertEqual(events.unclear, [0])
        XCTAssertTrue(pipeline.speaker?.placed.isEmpty == true)
        pipeline.stop()
    }

    @MainActor func testTerminalFailureLeavesSessionInRetryState() {
        let session = LiveSession()
        session.apply(.failed("Recognition unavailable"))
        XCTAssertFalse(session.isLive)
        XCTAssertEqual(session.phase, .failed("Recognition unavailable"))
        XCTAssertEqual(session.notice, "Recognition unavailable")
    }

    @MainActor func testInactiveSessionCannotStartOrLoadModels() async {
        let session = LiveSession()
        session.setActive(false)
        await session.start()
        await session.prepare()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isBusy)
    }

    func testQualityChecksKeepAmbiguityAndLegitimateContentSeparate() {
        XCTAssertNotNil(TranslationQuality.concern(source: "Verso le 7-5."))
        XCTAssertNil(TranslationQuality.concern(source: "Verso le 6:55."))
        XCTAssertNil(TranslationQuality.concern(source: "Il punteggio è 7-5."))
        XCTAssertNil(TranslationQuality.concern(source: "Open from 7-5."))
        XCTAssertNotNil(TranslationQuality.concern(source: "M. Wer kann", translation: "Mr. [Name], whoever can"))
        XCTAssertNil(TranslationQuality.concern(source: "M. Dupont arrive.", translation: "Mr. Dupont is coming."))
        XCTAssertNil(TranslationQuality.concern(source: "Remplissez [Name].", translation: "Fill in [Name]."))
        XCTAssertNotNil(TranslationQuality.concern(source: "Bonjour.", translation: "  "))
    }

    private func makePipeline(_ fault: Fault) -> Pipeline {
        Pipeline(recognition: TestRecognizer(fault: fault), translation: TestLinguist(fault: fault),
                 synthesis: TestVoice(fault: fault), makeVAD: { TestVAD(fault: fault) })
    }
}

private enum Fault: Error, Sendable { case vad, recognition, translation, voice, judge, unclear }
private struct TestRecognizer: SpeechRecognizing {
    let fault: Fault
    func transcribe(_ samples: [Float], offset: Double) async throws -> [Word] {
        if fault == .recognition { throw fault }
        return [Word("Bonjour", 0, 0.3), Word("tout", 0.3, 0.6), Word("monde.", 0.6, 0.9)]
    }
}
private actor TestLinguist: SpeechInterpreting {
    let fault: Fault
    nonisolated let model: TranslationModel
    init(fault: Fault) {
        self.fault = fault
        model = ModelCatalog.translation[fault == .judge ? 1 : 0]
    }
    func complete(_ text: String) throws -> Bool { if fault == .judge { throw fault }; return true }
    func gate(_ text: String) -> Silence? { nil }
    func remember(_ text: String) {}
    func translate(_ text: String, brief: Bool) throws -> String {
        if fault == .translation { throw fault }
        if fault == .unclear { throw UnclearTranslation("Please repeat the time.") }
        return "Hello everyone."
    }
}
private struct TestVoice: SpeechSynthesizing {
    let fault: Fault
    let sampleRate = 16_000.0
    func speak(_ text: String, pace: Double) throws -> [Float] {
        if fault == .voice { throw fault }
        return [Float](repeating: 0.1, count: 1_600)
    }
}
private final class TestVAD: SpeechDetecting, @unchecked Sendable {
    let fault: Fault
    var lastSpeech = 1.0
    init(fault: Fault) { self.fault = fault }
    func push(_ frame: ArraySlice<Float>, at: Double) throws -> Bool { if fault == .vad { throw fault }; return true }
    func silence(at: Double) -> Double { 0.6 }
}
private final class TestSource: AudioSource, @unchecked Sendable {
    let buffer = SampleBuffer()
    let finished: Bool
    private let lock = NSLock()
    private var didStop = false
    var stopped: Bool { lock.withLock { didStop } }
    init(finished: Bool = true) { self.finished = finished }
    func start() { buffer.append([Float](repeating: 0, count: 16_000)) }
    func stop() { lock.withLock { didStop = true } }
}
private final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PipelineEvent] = []
    func append(_ event: PipelineEvent) { lock.withLock { items.append(event) } }
    var failures: [String] { lock.withLock { items.compactMap { if case .failed(let text) = $0 { text } else { nil } } } }
    var unclear: [Int] { lock.withLock { items.compactMap { if case .silent(let id, .unclear, _) = $0 { id } else { nil } } } }
}
