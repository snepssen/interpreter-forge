import Foundation
import InterpreterCore
import SampleBuffer
import SileroVAD
@testable import MLXLMCommon
import XCTest
@testable import InterpreterEngine

final class LifecycleTests: XCTestCase {
    func testSampleBufferPreservesAbsoluteStreamIndicesAfterDrop() {
        let buffer = SampleBuffer()
        buffer.append([1, 2, 3, 4])
        buffer.drop(before: 3)
        buffer.append([5, 6])
        XCTAssertEqual(buffer.count, 6)
        XCTAssertEqual(buffer.read(0, 6), [4, 5, 6])
        XCTAssertEqual(buffer.read(0, 1), [])
        buffer.drop(before: 100)
        XCTAssertEqual(buffer.count, 6)
        XCTAssertTrue(buffer.everything().isEmpty)
    }

    func testConcurrentAppendReadAndMeter() async {
        let buffer = SampleBuffer()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<1_000 { buffer.append([0.25]) } }
            group.addTask {
                for _ in 0..<1_000 {
                    _ = buffer.level
                    _ = buffer.read(0, buffer.count)
                }
            }
        }
        XCTAssertEqual(buffer.count, 1_000)
        XCTAssertEqual(buffer.level, 0.25)
    }

    func testStoppedSpeakerRejectsLateClips() throws {
        let speaker = try Speaker(sampleRate: 16_000, audible: false) { 0 }
        speaker.play([Float](repeating: 0.1, count: 16_000))
        XCTAssertEqual(speaker.backlog, 1)
        speaker.stop()
        speaker.play([Float](repeating: 0.1, count: 16_000))
        XCTAssertEqual(speaker.placed.count, 1)
        XCTAssertEqual(speaker.backlog, 0)
    }

    func testInboxDropsWorkAfterClose() async {
        let inbox = Inbox()
        await inbox.put(piece(0, "first"))
        await inbox.close()
        await inbox.put(piece(1, "late"))
        let received = await inbox.takeAll()
        XCTAssertNil(received)
    }

    func testInboxFinishesQueuedWorkOnce() async {
        let inbox = Inbox()
        await inbox.put(piece(0, "first"))
        await inbox.finish()
        await inbox.put(piece(1, "late"))
        let first = await inbox.takeAll()
        let last = await inbox.takeAll()
        XCTAssertEqual(first?.map(\.index), [0])
        XCTAssertNil(last)
    }

    @MainActor func testTranscriptIDsAndMergingAcrossRestarts() {
        let session = LiveSession()
        session.beginTranscript()
        session.apply(.committed(piece(0, "old")))
        session.apply(.interpreted(indices: [0], translation: "old translation", playStart: 0, lags: [1], brief: false, pace: 1))
        session.stop()
        session.beginTranscript()
        session.apply(.committed(piece(0, "new")))
        session.apply(.committed(piece(1, "tail")))
        session.apply(.interpreted(indices: [0, 1], translation: "new translation", playStart: 0, lags: [2], brief: false, pace: 1))
        XCTAssertEqual(session.lines.count, 2)
        XCTAssertEqual(Set(session.lines.map(\.id)).count, 2)
        XCTAssertEqual(session.lines[0].source, "old")
        XCTAssertEqual(session.lines[0].translation, "old translation")
        XCTAssertEqual(session.lines[1].source, "new tail")
        XCTAssertEqual(session.lines[1].translation, "new translation")
    }

    @MainActor func testClearedTranscriptDoesNotReuseIDs() {
        let session = LiveSession()
        session.beginTranscript()
        session.apply(.committed(piece(0, "old")))
        let old = session.lines[0].id
        session.clear()
        session.beginTranscript()
        session.apply(.committed(piece(0, "new")))
        XCTAssertNotEqual(session.lines[0].id, old)
    }

    func testPromptCacheRebuildsWhenRewindIsUnavailable() throws {
        let old = FakeCache()
        var cache = try PromptCache { [old.offset == 0 ? old : FakeCache()] }
        old.offset = 4
        cache.settle([1, 2, 3, 4])
        old.trimmable = false
        XCTAssertEqual(try cache.prepare(for: [1, 2, 9]), [1, 2, 9])
        XCTAssertEqual(cache.kv[0].offset, 0)
        XCTAssertFalse((cache.kv[0] as? FakeCache) === old)
    }

    func testPromptCacheNeverSkipsUncachedLastToken() throws {
        let backing = FakeCache()
        var cache = try PromptCache { [backing] }
        backing.offset = 2
        cache.settle([1, 2, 3])
        XCTAssertEqual(try cache.prepare(for: [1, 2, 3, 4]), [3, 4])
    }

    func testEmptyPromptIsAnError() throws {
        var cache = try PromptCache { [FakeCache()] }
        XCTAssertThrowsError(try cache.prepare(for: []))
    }

    func testLanguageCandidatesIncludeEveryPickerLanguage() {
        let codes = Set(LanguageDetector.candidates.map(\.rawValue))
        XCTAssertTrue(Set(Languages.names.keys).isSubset(of: codes))
    }

    func testModelStoreRejectsPartialDownloadsAndReusesCompleteFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = TranslationModel(id: "test", name: "Test", tagline: "", summary: "", repo: "", revision: "",
                                     style: .instructions, memoryGB: 0,
                                     files: [.init(name: "weights", size: 3), .init(name: "config", size: 2)])
        try Data([1, 2, 3]).write(to: folder.appending(path: "weights"))
        XCTAssertNil(ModelStore.location(of: model, in: [folder]))
        try Data([1]).write(to: folder.appending(path: "config"))
        XCTAssertNil(ModelStore.location(of: model, in: [folder]))
        try Data([1, 2]).write(to: folder.appending(path: "config"))
        XCTAssertEqual(ModelStore.location(of: model, in: [folder]), folder)
    }

    func testVoiceProducesFiniteAudio() throws {
        guard let model = Resources.voice, let data = Resources.espeakData else {
            throw XCTSkip("Voice assets are not present on this checkout")
        }
        let voice = try Voice(model: model, espeakData: data)
        let samples = try voice.speak("The train leaves at 10:30. Please meet me at the station.")
        XCTAssertGreaterThan(samples.count, Int(voice.sampleRate))
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 0.901)
    }

    func testVADSilenceDoesNotBecomeSpeech() throws {
        guard let model = Resources.vad else { throw XCTSkip("VAD asset is not present") }
        let vad = try SileroVAD(model: model)
        let silence = [Float](repeating: 0, count: SileroVAD.frame)
        for frame in 1...100 {
            XCTAssertFalse(try vad.push(silence[...], at: Double(frame) * 0.032))
        }
        XCTAssertLessThan(vad.lastSpeech, 0)
    }

    private func piece(_ index: Int, _ text: String) -> Segment {
        Segment(index: index, words: [Word(text, 0, 1)], reason: "test", decidedAt: 1)
    }
}

private final class FakeCache: BaseKVCache {
    var trimmable = true
    override var isTrimmable: Bool { trimmable }
    override func trim(_ n: Int) -> Int {
        let trimmed = min(offset, max(0, n))
        offset -= trimmed
        return trimmed
    }
}
