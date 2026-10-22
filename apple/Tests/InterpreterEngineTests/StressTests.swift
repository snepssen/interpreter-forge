import Foundation
import InterpreterCore
import SampleBuffer
import SileroVAD
import XCTest
@testable import InterpreterEngine

final class StressTests: XCTestCase {
    func testStopDuringEachStageRejectsLateEffectsAcrossRestarts() async throws {
        for cycle in 0..<5 {
            for stage in PauseStage.allCases {
                let entered = expectation(description: "cycle \(cycle), entered \(stage)")
                let barrier = StageBarrier(entered: entered)
                let source = StressSource(endsImmediately: stage != .judge)
                if stage == .judge { source.buffer.append([Float](repeating: 0, count: 16_000)) }
                let recognizer = PausingRecognizer(stage: stage, barrier: barrier)
                let linguist = PausingLinguist(stage: stage, barrier: barrier)
                let voice = PausingVoice(stage: stage, barrier: barrier)
                let events = StopEvents()
                let pipeline = Pipeline(recognition: recognizer, translation: linguist, synthesis: voice,
                                        makeVAD: { SilentDetector(speaking: stage == .judge) })
                try pipeline.start(source: source, speaker: nil, audible: false) { events.append($0) }
                if stage == .judge {
                    try await Task.sleep(for: .milliseconds(100))
                    source.buffer.append([Float](repeating: 0, count: 16_000))
                }
                await fulfillment(of: [entered], timeout: 3)
                events.markStopped()
                pipeline.stop()
                pipeline.stop()
                barrier.release()
                let finished = expectation(description: "cycle \(cycle), drained \(stage)")
                Task { await pipeline.finish(); finished.fulfill() }
                await fulfillment(of: [finished], timeout: 3)
                XCTAssertNil(pipeline.failure)
                XCTAssertTrue(source.stopped)
                XCTAssertEqual(events.lateEffects, 0, "late effect after stopping \(stage)")
                XCTAssertTrue(pipeline.speaker?.placed.isEmpty == true)
                if stage == .gate {
                    let remembered = await linguist.remembered
                    XCTAssertEqual(remembered, 0, "cancelled gate must not start another stage")
                }
                if stage == .gate || stage == .remember {
                    let translated = await linguist.translated
                    XCTAssertEqual(translated, 0)
                }
            }
        }
    }

    func testTenMinutesOfSilenceKeepsInputBoundedAndAvoidsRecognition() async throws {
        guard let vad = Resources.vad else { throw XCTSkip("VAD model unavailable") }
        let source = StressSource(endsImmediately: false)
        let recognizer = CountingRecognizer()
        let barrier = StageBarrier(entered: nil)
        let pipeline = Pipeline(recognition: recognizer,
                                translation: PausingLinguist(stage: .translation, barrier: barrier),
                                synthesis: PausingVoice(stage: .translation, barrier: barrier),
                                makeVAD: { try SileroVAD(model: vad) })
        let events = StopEvents()
        try pipeline.start(source: source, speaker: nil, audible: false) { events.append($0) }
        defer { pipeline.stop(); barrier.release() }
        let silence = [Float](repeating: 0, count: 16_000)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        for _ in 0..<600 {
            while source.buffer.everything().count > 64_000 {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    XCTFail("Silent input was not released"); return
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            source.buffer.append(silence)
        }
        while source.buffer.everything().count > 40_000 {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Final silent input was not released"); return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(source.buffer.count, 600 * 16_000)
        XCTAssertLessThanOrEqual(source.buffer.everything().count, 40_000)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(pipeline.failure)
        pipeline.stop()
        await pipeline.finish()
    }
}

private enum PauseStage: CaseIterable, Sendable { case recognition, judge, gate, remember, translation, voice }

private final class StageBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: XCTestExpectation?
    private var enteredOnce = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation?) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if !enteredOnce { enteredOnce = true; entered?.fulfill() }
            if released { condition.unlock(); continuation.resume() }
            else { waiter = continuation; condition.unlock() }
        }
    }
    func waitSynchronously() {
        condition.lock()
        if !enteredOnce { enteredOnce = true; entered?.fulfill() }
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        let continuation = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()
        continuation?.resume()
    }
}
private actor PausingRecognizer: SpeechRecognizing {
    let stage: PauseStage
    let barrier: StageBarrier
    init(stage: PauseStage, barrier: StageBarrier) { self.stage = stage; self.barrier = barrier }
    func transcribe(_ samples: [Float], offset: Double) async throws -> [Word] {
        if stage == .recognition { await barrier.wait() }
        return [Word("Bonjour", 0, 0.3), Word("tout", 0.3, 0.6), Word("monde.", 0.6, 0.9)]
    }
}
private actor CountingRecognizer: SpeechRecognizing {
    private(set) var calls = 0
    func transcribe(_ samples: [Float], offset: Double) -> [Word] { calls += 1; return [] }
}
private actor PausingLinguist: SpeechInterpreting {
    nonisolated let model: TranslationModel
    let stage: PauseStage
    let barrier: StageBarrier
    private(set) var remembered = 0
    private(set) var translated = 0
    init(stage: PauseStage, barrier: StageBarrier) {
        self.stage = stage; self.barrier = barrier
        model = ModelCatalog.translation[stage == .judge ? 1 : 0]
    }
    func complete(_ text: String) async -> Bool {
        if stage == .judge { await barrier.wait() }
        return true
    }
    func gate(_ text: String) async -> Silence? {
        if stage == .gate { await barrier.wait() }
        return stage == .gate || stage == .remember ? .understood : nil
    }
    func remember(_ text: String) async {
        remembered += 1
        if stage == .remember { await barrier.wait() }
    }
    func translate(_ text: String, brief: Bool) async -> String {
        translated += 1
        if stage == .translation { await barrier.wait() }
        return "Hello everyone."
    }
}
private struct PausingVoice: SpeechSynthesizing {
    let stage: PauseStage
    let barrier: StageBarrier
    let sampleRate = 16_000.0
    func speak(_ text: String, pace: Double) -> [Float] {
        if stage == .voice { barrier.waitSynchronously() }
        return [Float](repeating: 0.1, count: 1_600)
    }
}
private final class StressSource: AudioSource, @unchecked Sendable {
    let buffer = SampleBuffer()
    private let endsImmediately: Bool
    private let lock = NSLock()
    private var didStop = false
    var finished: Bool { endsImmediately }
    var stopped: Bool { lock.withLock { didStop } }
    init(endsImmediately: Bool = true) { self.endsImmediately = endsImmediately }
    func start() { if endsImmediately { buffer.append([Float](repeating: 0, count: 16_000)) } }
    func stop() { lock.withLock { didStop = true } }
}
private struct SilentDetector: SpeechDetecting {
    var speaking = false
    var lastSpeech: Double { speaking ? 1 : -1e9 }
    func push(_ frame: ArraySlice<Float>, at: Double) -> Bool { speaking }
    func silence(at: Double) -> Double { speaking ? 0.6 : at + 1e9 }
}
private final class StopEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var late = 0
    var lateEffects: Int { lock.withLock { late } }
    func markStopped() { lock.withLock { stopped = true } }
    func append(_ event: PipelineEvent) {
        lock.withLock {
            guard stopped else { return }
            switch event {
            case .committed, .interpreted, .silent, .hearing: late += 1
            default: break
            }
        }
    }
}
