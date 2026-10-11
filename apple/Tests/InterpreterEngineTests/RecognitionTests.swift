import Foundation
import AVFoundation
import InterpreterCore
import WhisperKit
import XCTest
@testable import InterpreterEngine

final class RecognitionTests: XCTestCase {
    /// Explicit opt-in: exercise the real downloader, Core ML models and cache
    /// on a recording; never download gigabytes during the ordinary test suite.
    func testInstalledRecognitionOnRecording() async throws {
        guard let id = ProcessInfo.processInfo.environment["TC_RECOGNITION_MODEL"],
              let model = RecognitionModel(rawValue: id),
              let path = ProcessInfo.processInfo.environment["TC_RECOGNITION_AUDIO"] else {
            throw XCTSkip("Set TC_RECOGNITION_MODEL and TC_RECOGNITION_AUDIO for the model acceptance check")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(file.length, Int64(file.processingFormat.sampleRate * 10))))!
        try file.read(into: input)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000)!
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if let conversionError { throw conversionError }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        let requireCached = ProcessInfo.processInfo.environment["TC_REQUIRE_CACHED"] == "1"
        if requireCached { XCTAssertTrue(RecognitionStore.complete(in: RecognitionStore.whisperBase)) }
        let progress = RecognitionProgress()
        let recognizer = try await Recognizer.load(model: model, languages: ["en"], progress: { progress.record($0) })
        if requireCached { XCTAssertFalse(progress.downloaded) }
        let started = Date()
        let words = try await recognizer.transcribe(samples, offset: 20)
        print("Recognition acceptance: \(model.rawValue), \(samples.count) samples, \(words.count) words, \(Date().timeIntervalSince(started)) s")
        XCTAssertFalse(words.isEmpty)
        XCTAssertTrue(words.allSatisfy { !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 20 && $0.end >= $0.start })
        if model == .whisper { XCTAssertTrue(RecognitionStore.complete(in: RecognitionStore.whisperBase)) }
    }

    func testWhisperTimesAreWindowRelativeAndBounded() {
        let tokens: [WordTiming] = [
            .init(word: " Hallo", tokens: [], start: 0.2, end: 0.7, probability: 1),
            .init(word: "wereld.", tokens: [], start: 0.8, end: 4, probability: 1),
            .init(word: " ", tokens: [], start: 0, end: 1, probability: 1),
            .init(word: "invalid", tokens: [], start: .nan, end: 1, probability: 1),
            .init(word: "reversed", tokens: [], start: 1, end: 0, probability: 1),
            .init(word: "past window", tokens: [], start: 3, end: 4, probability: 1),
        ]
        let words = Recognizer.whisperWords(tokens, offset: 10, duration: 2)
        XCTAssertEqual(words.map(\.text), ["Hallo", "wereld."])
        XCTAssertEqual(words[0].start, 10.2, accuracy: 0.0001)
        XCTAssertEqual(words[0].end, 10.7, accuracy: 0.0001)
        XCTAssertEqual(words[1].end, 12)
    }

    func testRecognitionCoverageAndSwitchFilter() {
        let parakeet = RecognitionModel.parakeetUltra
        let whisper = RecognitionModel.whisper
        XCTAssertEqual(parakeet.languageNames.count, 25)
        XCTAssertEqual(whisper.languageNames.count, 100)
        for code in ["nl", "ro", "hu"] {
            XCTAssertNotNil(parakeet.languageNames[code])
            XCTAssertNotNil(whisper.languageNames[code])
        }
        XCTAssertEqual(parakeet.supportedFilter(["en", "hu", "ja"]), ["en", "hu"])
        XCTAssertEqual(whisper.supportedFilter(["en", "hu", "ja"]), ["en", "hu", "ja"])
        XCTAssertEqual(whisper.supportedFilter(["ja"]), ["en", "ja"])
        XCTAssertEqual(Languages.list(["ja"], names: whisper.languageNames), "Japanese")
        XCTAssertNil(Languages.evidence("مرحبا بالعالم", ["en", "ar"]))
    }

    func testCompletionRecordRejectsPartialOrTruncatedCaches() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let weights = folder.appending(path: "weights")
        try Data([1, 2, 3]).write(to: weights)
        XCTAssertFalse(RecognitionStore.complete(in: folder))
        try RecognitionStore.markComplete(in: folder)
        XCTAssertTrue(RecognitionStore.complete(in: folder))
        try Data([1, 2]).write(to: weights)
        XCTAssertFalse(RecognitionStore.complete(in: folder))
        try FileManager.default.removeItem(at: weights)
        XCTAssertFalse(RecognitionStore.complete(in: folder))
    }
}

private final class RecognitionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var sawDownload = false
    func record(_ fraction: Double) { lock.withLock { if fraction < 1 { sawDownload = true } } }
    var downloaded: Bool { lock.withLock { sawDownload } }
}
