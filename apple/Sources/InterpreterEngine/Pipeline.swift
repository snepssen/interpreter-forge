@preconcurrency import AVFoundation
import Foundation
import InterpreterCore
import SampleBuffer
import SileroVAD

/// What happens to the speech, as it happens.
public enum PipelineEvent: Sendable {
    /// What is being heard and not yet committed.
    case hearing(String)
    case committed(Segment)
    /// Not spoken, and why; `translation` holds an echo or a clarification message.
    case silent(index: Int, Silence, translation: String?)
    /// Translated and queued to play at `playStart` (session seconds). `indices`
    /// are the pieces merged into it; `lags` each one's wait from its end to then.
    /// `into` names the language in a two-way conversation; nil one way round.
    case interpreted(indices: [Int], translation: String, playStart: Double, lags: [Double], brief: Bool, pace: Double,
                     into: String? = nil)
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
    /// Which way a piece goes in a two-way conversation; nil one way round.
    func direction(_ text: String) async -> Direction?
    func translate(_ text: String, brief: Bool, direction: Direction?) async throws -> String
}
extension SpeechInterpreting {
    func direction(_ text: String) async -> Direction? { nil }
    func translate(_ text: String, brief: Bool, direction: Direction?) async throws -> String {
        try await translate(text, brief: brief)
    }
}
protocol SpeechSynthesizing: Sendable {
    var sampleRate: Double { get }
    func speak(_ text: String, pace: Double) throws -> [Float]
    /// In `language`, or the voice's own when nil.
    func speak(_ text: String, pace: Double, language: String?) throws -> [Float]
}
extension SpeechSynthesizing {
    func speak(_ text: String, pace: Double, language: String?) throws -> [Float] { try speak(text, pace: pace) }
}
protocol SpeechDetecting: Sendable {
    var lastSpeech: Double { get }
    func push(_ frame: ArraySlice<Float>, at: Double) throws -> Bool
    func silence(at: Double) -> Double
}
extension Recognizer: SpeechRecognizing {}
extension Linguist: SpeechInterpreting {
    func translate(_ text: String, brief: Bool) throws -> String { try translate(text, brief: brief, direction: nil) }
}
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
    private var summarising = false
    /// When the listener falls behind, say the gist instead of the whole
    /// translation. Off unless chosen: uneven speech is meant to queue, and a
    /// pause or a slow build-up is context, not something to cut. Only a model
    /// that takes instructions can do it; TranslateGemma always translates in
    /// full, and a piece is never marked shortened when it wasn't.
    public var summarises: Bool {
        get { control.withLock { summarising } }
        set { control.withLock { summarising = newValue } }
    }
    public var failure: String? { control.withLock { terminalFailure } }
    private let inbox = Inbox()
    private let started = ProcessInfo.processInfo.systemUptime
    public var level: Float { source?.buffer.level ?? 0 }
    /// Frames the microphone has delivered; nil for a recording.
    public var microphoneFrames: Int? { (source as? Microphone)?.framesReceived }
    public var enginesRunning: Bool { audioEngines.allSatisfy(\.isRunning) }
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
        let running = control.withLock { self.tasks }
        for task in running { await task.value }
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
        // What the voice said, in a two-way conversation: from the phone's
        // speaker the microphone hears it, and it would go back the other way.
        var echoes = SpokenEchoes()
        while !Task.isCancelled, let waiting = await inbox.takeAll() {
            var foreign: [(segment: Segment, direction: Direction?)] = []
            do {
                // Everything waiting goes as one: what the gate turns away set
                // aside, the rest merged into a single translation. Both ways
                // round, one per run of the same side.
                for segment in waiting {
                    try Task.checkCancellation()
                    if echoes.heard(segment.text, from: segment.start, to: segment.end) {
                        events(.silent(index: segment.index, .echo, translation: nil))
                        continue
                    }
                    let reason = await linguist.gate(segment.text)
                    try Task.checkCancellation()
                    if let why = reason {
                        if why == .understood {
                            await linguist.remember(segment.text)
                            try Task.checkCancellation()
                        }
                        events(.silent(index: segment.index, why, translation: nil))
                    } else {
                        foreign.append((segment, await linguist.direction(segment.text)))
                        try Task.checkCancellation()
                    }
                }
            } catch {
                if Task.isCancelled { return }
                fail("Interpreting: \(error.localizedDescription)", events)
                return
            }
            for run in Self.runs(foreign) {
                do {
                    try await say(run.segments, run.direction, speaker, &echoes, events)
                } catch let concern as UnclearTranslation {
                    if Task.isCancelled { return }
                    for segment in run.segments {
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

    /// Consecutive pieces going the same way, in order.
    static func runs(_ pieces: [(segment: Segment, direction: Direction?)])
        -> [(segments: [Segment], direction: Direction?)] {
        var runs: [(segments: [Segment], direction: Direction?)] = []
        for piece in pieces {
            if let last = runs.last, last.direction == piece.direction {
                runs[runs.count - 1].segments.append(piece.segment)
            } else {
                runs.append(([piece.segment], piece.direction))
            }
        }
        return runs
    }

    /// Translate `segments` as one piece and say it.
    private func say(_ segments: [Segment], _ direction: Direction?, _ speaker: Speaker,
                     _ echoes: inout SpokenEchoes, _ events: @Sendable (PipelineEvent) -> Void) async throws {
        let piece = Segment.combine(segments)
        let brief = summarises && linguist.model.judges && (backlog?.brief(speaker.backlog) ?? false)
        var direction = direction
        var translation = try await linguist.translate(piece.text, brief: brief, direction: direction)
        try Task.checkCancellation()
        if let way = direction, InterpreterCore.echoes(piece.text, translation) {
            // Translated into its own language: it was the other side
            // speaking. Once the other way round; a second echo is garbled.
            let other = try await linguist.translate(piece.text, brief: brief, direction: way.reversed)
            try Task.checkCancellation()
            if !InterpreterCore.echoes(piece.text, other) {
                direction = way.reversed
                translation = other
            }
        }
        if InterpreterCore.echoes(piece.text, translation) {
            for segment in segments {
                events(.silent(index: segment.index, .echo, translation: translation))
            }
            return
        }
        let pace = backlog?.pace(speaker.backlog) ?? 1
        var start = clock()  // shown now: the lag is the wait for the text
        if speaks {
            do {
                let samples = try voice.speak(translation, pace: pace, language: direction?.into)
                try Task.checkCancellation()
                start = speaker.play(samples)
                if direction != nil {
                    echoes.said(translation, from: start, to: start + Double(samples.count) / voice.sampleRate)
                }
            } catch where direction != nil && !(error is CancellationError) {
                // The other side's language may be one the voice can't read:
                // shown, not spoken, rather than ending the conversation.
                audioLog("voice couldn't say \(direction!.into): \(error.localizedDescription)")
            }
        }
        let ends = piece.parts.isEmpty ? [piece.end] : piece.parts
        events(.interpreted(indices: segments.map(\.index), translation: translation, playStart: start,
                            lags: ends.map { start - $0 }, brief: brief, pace: pace, into: direction?.into))
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
