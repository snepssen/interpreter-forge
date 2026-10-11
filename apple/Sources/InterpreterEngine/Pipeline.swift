@preconcurrency import AVFoundation
import Foundation
import InterpreterCore

/// What happens to the speech, as it happens.
public enum PipelineEvent: Sendable {
    /// What is being heard and not yet committed.
    case hearing(String)
    case committed(Segment)
    /// Not spoken, and why; `translation` holds an echo or a clarification message.
    case silent(index: Int, Silence, translation: String?)
    /// Translated and queued to play at `playStart` (session seconds). `indices`
    /// are the pieces merged into it; `lags` each one's wait from its end to then.
    case interpreted(indices: [Int], translation: String, playStart: Double, lags: [Double], brief: Bool, pace: Double)
    /// Terminal failure: capture and playback have stopped.
    case failed(String)
}

// Stage interfaces let failure and cancellation checks run without loading GBs
// of models or opening a real microphone.
protocol SpeechRecognizing: Sendable {
    func transcribe(_ samples: [Float], offset: Double) async throws -> [Word]
}
protocol SpeechInterpreting: Sendable {
    var model: TranslationModel { get }
    func complete(_ text: String) async throws -> Bool
    func gate(_ text: String) async -> Silence?
    func remember(_ text: String) async
    func translate(_ text: String, brief: Bool) async throws -> String
}
protocol SpeechSynthesizing: Sendable {
    var sampleRate: Double { get }
    func speak(_ text: String, pace: Double) throws -> [Float]
}
protocol SpeechDetecting: Sendable {
    var lastSpeech: Double { get }
    func push(_ frame: ArraySlice<Float>, at: Double) throws -> Bool
    func silence(at: Double) -> Double
}
extension Recognizer: SpeechRecognizing {}
extension Linguist: SpeechInterpreting {}
extension Voice: SpeechSynthesizing {}
extension SileroVAD: SpeechDetecting {}

/// The live loop: one task listens and cuts, another interprets what was cut.
///
/// In Python both shared the GPU and translation had to go first. Here speech
/// recognition runs on the Neural Engine and translation on the GPU, so they
/// run side by side; only the judge waits its turn at the translation model.
public final class Pipeline: @unchecked Sendable {
    let recognizer: any SpeechRecognizing
    let linguist: any SpeechInterpreting
    let voice: any SpeechSynthesizing
    private let makeVAD: @Sendable () throws -> any SpeechDetecting
    let config: SegmenterConfig
    let backlog: Backlog?
    private var source: AudioSource?
    public private(set) var speaker: Speaker?
    private var tasks: [Task<Void, Never>] = []
    private let control = NSLock()
    private var stopped = false
    private var terminalFailure: String?
    private var speaking = true
    /// Off for captions only: translations are shown but not voiced, so
    /// nothing queues in the headphones and nothing has to catch up.
    public var speaks: Bool {
        get { control.withLock { speaking } }
        set { control.withLock { speaking = newValue } }
    }
    public var failure: String? { control.withLock { terminalFailure } }
    private let inbox = Inbox()
    private let started = ProcessInfo.processInfo.systemUptime
    public var level: Float { source?.buffer.level ?? 0 }
    var audioEngines: [AVAudioEngine] {
        var engines = (source as? Microphone).map { [$0.audioEngine] } ?? []
        if let engine = speaker?.audioEngine, !engines.contains(where: { $0 === engine }) { engines.append(engine) }
        return engines
    }

    public convenience init(recognizer: Recognizer, linguist: Linguist, voice: Voice, vad: URL,
                            config: SegmenterConfig = SegmenterConfig(), backlog: Backlog? = Backlog()) {
        self.init(recognition: recognizer, translation: linguist, synthesis: voice,
                  makeVAD: { try SileroVAD(model: vad) }, config: config, backlog: backlog)
    }

    init(recognition recognizer: any SpeechRecognizing, translation linguist: any SpeechInterpreting,
         synthesis voice: any SpeechSynthesizing, makeVAD: @escaping @Sendable () throws -> any SpeechDetecting,
         config: SegmenterConfig = SegmenterConfig(), backlog: Backlog? = Backlog()) {
        self.recognizer = recognizer
        self.linguist = linguist
        self.voice = voice
        self.makeVAD = makeVAD
        self.config = config
        self.backlog = backlog
    }

    /// Session seconds; the stream clock, give or take the input's latency.
    func clock() -> Double { (ProcessInfo.processInfo.systemUptime - started) }

    public func start(microphone device: String?, speaker output: String?,
                      events: @escaping @Sendable (PipelineEvent) -> Void) throws {
        #if os(iOS)
        try PhoneAudio.activate(PhoneAudio.Input(device))
        #endif
        do {
            #if os(iOS)
            let engine = AVAudioEngine()
            try start(source: Microphone(device: device, engine: engine), speaker: output,
                      audible: true, engine: engine, events: events)
            #else
            try start(source: Microphone(device: device), speaker: output, audible: true, events: events)
            #endif
        } catch {
            #if os(iOS)
            PhoneAudio.deactivate()
            #endif
            throw error
        }
    }

    public func start(source: AudioSource, speaker output: String?, audible: Bool,
                      events: @escaping @Sendable (PipelineEvent) -> Void) throws {
        try start(source: source, speaker: output, audible: audible, engine: nil, events: events)
    }

    private func start(source: AudioSource, speaker output: String?, audible: Bool, engine: AVAudioEngine?,
                       events: @escaping @Sendable (PipelineEvent) -> Void) throws {
        let speaker = try Speaker(sampleRate: voice.sampleRate, device: output, audible: audible, engine: engine) { [started] in
            (ProcessInfo.processInfo.systemUptime - started)
        }
        do {
            let vad = try makeVAD()
            try source.start()
            if engine != nil { try speaker.start() }
            self.source = source
            self.speaker = speaker
            control.withLock {
                tasks = [
                    Task.detached { [self] in await listen(source, vad, events) },
                    Task.detached { [self] in await interpret(speaker, events) },
                ]
            }
        } catch {
            source.stop()
            speaker.stop()
            throw error
        }
    }

    public func stop() {
        control.withLock {
            guard !stopped else { return }
            stopped = true
            tasks.forEach { $0.cancel() }
            Task { await inbox.close() }
            source?.stop()
            speaker?.stop()
            #if os(iOS)
            PhoneAudio.deactivate()
            #endif
        }
    }

    /// Wait until a recording has been heard to the end and everything in it said.
    public func finish() async {
        let tasks = control.withLock { tasks }
        for task in tasks { await task.value }
    }

    private func fail(_ message: String, _ events: @Sendable (PipelineEvent) -> Void) {
        let report = control.withLock {
            guard !stopped, terminalFailure == nil else { return false }
            terminalFailure = message
            return true
        }
        guard report else { return }
        stop()
        events(.failed(message))
    }

    // MARK: listening

    private func listen(_ source: AudioSource, _ vad: any SpeechDetecting, _ events: @escaping @Sendable (PipelineEvent) -> Void) async {
        let buffer = source.buffer
        let linguist = linguist
        // Only a general model judges; without one the segmenter cuts on pauses
        // and punctuation alone, rather than on a judge that always says yes.
        var judge: (@Sendable (String) async -> Bool)?
        if linguist.model.judges {
            judge = { @Sendable [self] text in
                do { return try await linguist.complete(text) }
                catch {
                    if !Task.isCancelled { fail("Checking speech: \(error.localizedDescription)", events) }
                    return false
                }
            }
        }
        let segmenter = Segmenter(config: config, judge: judge)
        var vadAt = 0
        var lastHop = 0.0
        while !Task.isCancelled {
            let ended = source.finished
            let heard = buffer.count
            while vadAt + SileroVAD.frame <= heard {
                let frame = buffer.read(vadAt, vadAt + SileroVAD.frame)
                do {
                    try Task.checkCancellation()
                    _ = try vad.push(frame[...], at: Double(vadAt + SileroVAD.frame) / 16_000)
                } catch {
                    if !Task.isCancelled { fail("Detecting speech: \(error.localizedDescription)", events) }
                    return
                }
                vadAt += SileroVAD.frame
            }
            let now = Double(heard) / 16_000
            if ended {  // a recording ran out: say what is left, then let the interpreter finish
                let start = segmenter.windowStart()
                do {
                    let words = try await recognizer.transcribe(buffer.read(Int(start * 16_000), heard), offset: start)
                    try Task.checkCancellation()
                    for var segment in segmenter.flush(now: now, words: segmenter.newWords(words)) {
                        try Task.checkCancellation()
                        segment.decidedAt = clock()
                        events(.committed(segment))
                        await inbox.put(segment)
                    }
                    await inbox.finish()
                } catch {
                    if !Task.isCancelled { fail("Speech recognition: \(error.localizedDescription)", events) }
                }
                return
            }
            guard now - lastHop >= config.hop else {
                try? await Task.sleep(for: .milliseconds(30))
                continue
            }
            lastHop = now
            guard vad.lastSpeech > segmenter.mark else {
                segmenter.advanceIdle(now: now)
                buffer.drop(before: Int((segmenter.windowStart() - 1) * 16_000))
                continue
            }

            let start = segmenter.windowStart()
            let samples = buffer.read(Int(start * 16_000), heard)
            do {
                let words = segmenter.newWords(try await recognizer.transcribe(samples, offset: start))
                try Task.checkCancellation()
                let silence = vad.silence(at: now)
                let segments = await segmenter.step(now: now, words: words, silence: silence)
                try Task.checkCancellation()
                for var segment in segments {
                    try Task.checkCancellation()
                    segment.decidedAt = clock()
                    events(.committed(segment))
                    await inbox.put(segment)
                }
                events(.hearing(segmenter.pending.map(\.text).joined(separator: " ")))
                if words.isEmpty && (silence >= segmenter.longPauseThreshold() || now - start >= config.hardSegment) {
                    segmenter.advanceIdle(now: now)
                }
            } catch {
                if Task.isCancelled { return }
                fail("Speech recognition: \(error.localizedDescription)", events)
                return
            }
            buffer.drop(before: Int((segmenter.windowStart() - 1) * 16_000))  // keep a second spare
        }
    }

    // MARK: interpreting

    private func interpret(_ speaker: Speaker, _ events: @Sendable (PipelineEvent) -> Void) async {
        while !Task.isCancelled, let waiting = await inbox.takeAll() {
            var foreign: [Segment] = []
            do {
                // Everything waiting goes as one: what the gate turns away set
                // aside, the rest merged into a single translation.
                for segment in waiting {
                    try Task.checkCancellation()
                    let reason = await linguist.gate(segment.text)
                    try Task.checkCancellation()
                    if let why = reason {
                        if why == .english {
                            await linguist.remember(segment.text)
                            try Task.checkCancellation()
                        }
                        events(.silent(index: segment.index, why, translation: nil))
                    } else {
                        foreign.append(segment)
                    }
                }
                guard !foreign.isEmpty else { continue }
                let piece = Segment.combine(foreign)
                let brief = backlog?.brief(speaker.backlog) ?? false
                let translation = try await linguist.translate(piece.text, brief: brief)
                try Task.checkCancellation()
                if echoes(piece.text, translation) {
                    for segment in foreign {
                        events(.silent(index: segment.index, .echo, translation: translation))
                    }
                    continue
                }
                let pace = backlog?.pace(speaker.backlog) ?? 1
                let start: Double
                if speaks {
                    let samples = try voice.speak(translation, pace: pace)
                    try Task.checkCancellation()
                    start = speaker.play(samples)
                } else {
                    start = clock()  // shown now: the lag is the wait for the text
                }
                let ends = piece.parts.isEmpty ? [piece.end] : piece.parts
                events(.interpreted(indices: foreign.map(\.index), translation: translation, playStart: start,
                                    lags: ends.map { start - $0 }, brief: brief, pace: pace))
            } catch let concern as UnclearTranslation {
                if Task.isCancelled { return }
                for segment in foreign {
                    events(.silent(index: segment.index, .unclear, translation: concern.localizedDescription))
                }
            } catch {
                if Task.isCancelled { return }
                fail("Interpreting: \(error.localizedDescription)", events)
                return
            }
        }
    }
}

/// Committed pieces waiting for the interpreter; it takes them all at once.
actor Inbox {
    private var items: [Segment] = []
    private var waiter: CheckedContinuation<[Segment]?, Never>?
    private var closed = false
    private var finishing = false

    func put(_ segment: Segment) {
        guard !closed, !finishing else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: [segment])
        } else {
            items.append(segment)
        }
    }

    /// Everything waiting, or the next piece when it comes; nil once closed.
    func takeAll() async -> [Segment]? {
        if closed { return nil }
        if !items.isEmpty {
            defer {
                items.removeAll()
                if finishing { closed = true }
            }
            return items
        }
        if finishing { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        items.removeAll()
        waiter?.resume(returning: nil)
        waiter = nil
    }

    /// No more is coming: hand over what is waiting, then nothing.
    func finish() {
        finishing = true
        if items.isEmpty { close() }
    }
}
