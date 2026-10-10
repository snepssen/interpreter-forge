import Foundation
import InterpreterCore

/// What happens to the speech, as it happens.
public enum PipelineEvent: Sendable {
    /// What is being heard and not yet committed.
    case hearing(String)
    case committed(Segment)
    /// Not spoken, and why; `translation` if one was made (an echo).
    case silent(index: Int, Silence, translation: String?)
    /// Translated and queued to play at `playStart` (session seconds). `indices`
    /// are the pieces merged into it; `lags` each one's wait from its end to then.
    case interpreted(indices: [Int], translation: String, playStart: Double, lags: [Double], brief: Bool, pace: Double)
    case failed(String)
}

/// The live loop: one task listens and cuts, another interprets what was cut.
///
/// In Python both shared the GPU and translation had to go first. Here speech
/// recognition runs on the Neural Engine and translation on the GPU, so they
/// run side by side; only the judge waits its turn at the translation model.
public final class Pipeline: @unchecked Sendable {
    let recognizer: Recognizer
    let linguist: Linguist
    let voice: Voice
    let vadModel: URL
    let config: SegmenterConfig
    let backlog: Backlog?
    private var source: AudioSource?
    public private(set) var speaker: Speaker?
    private var tasks: [Task<Void, Never>] = []
    private let inbox = Inbox()
    private let started = Date()
    public var level: Float { source?.buffer.level ?? 0 }

    public init(recognizer: Recognizer, linguist: Linguist, voice: Voice, vad: URL,
                config: SegmenterConfig = SegmenterConfig(), backlog: Backlog? = Backlog()) {
        self.recognizer = recognizer
        self.linguist = linguist
        self.voice = voice
        self.vadModel = vad
        self.config = config
        self.backlog = backlog
    }

    /// Session seconds; the stream clock, give or take the input's latency.
    func clock() -> Double { Date().timeIntervalSince(started) }

    public func start(microphone device: String?, speaker output: String?,
                      events: @escaping @Sendable (PipelineEvent) -> Void) throws {
        #if os(iOS)
        try PhoneAudio.activate()
        #endif
        try start(source: Microphone(device: device), speaker: output, audible: true, events: events)
    }

    public func start(source: AudioSource, speaker output: String?, audible: Bool,
                      events: @escaping @Sendable (PipelineEvent) -> Void) throws {
        let speaker = try Speaker(sampleRate: voice.sampleRate, device: output, audible: audible) { [started] in
            Date().timeIntervalSince(started)
        }
        let vad = try SileroVAD(model: vadModel)
        try source.start()
        self.source = source
        self.speaker = speaker
        tasks = [
            Task.detached { [self] in await listen(source, vad, events) },
            Task.detached { [self] in await interpret(speaker, events) },
        ]
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        Task { await inbox.close() }
        source?.stop()
        speaker?.stop()
        #if os(iOS)
        PhoneAudio.deactivate()
        #endif
    }

    /// Wait until a recording has been heard to the end and everything in it said.
    public func finish() async {
        for task in tasks { await task.value }
    }

    // MARK: listening

    private func listen(_ source: AudioSource, _ vad: SileroVAD, _ events: @Sendable (PipelineEvent) -> Void) async {
        let buffer = source.buffer
        let linguist = linguist
        let segmenter = Segmenter(config: config) { text in (try? await linguist.complete(text)) ?? true }
        var vadAt = 0
        var lastHop = 0.0
        while !Task.isCancelled {
            let ended = source.finished
            let heard = buffer.count
            while vadAt + SileroVAD.frame <= heard {
                let frame = buffer.read(vadAt, vadAt + SileroVAD.frame)
                _ = try? vad.push(frame[...], at: Double(vadAt + SileroVAD.frame) / 16_000)
                vadAt += SileroVAD.frame
            }
            let now = Double(heard) / 16_000
            if ended {  // a recording ran out: say what is left, then let the interpreter finish
                let start = segmenter.windowStart()
                let words = (try? await recognizer.transcribe(buffer.read(Int(start * 16_000), heard), offset: start)) ?? []
                for var segment in segmenter.flush(now: now, words: segmenter.newWords(words)) {
                    segment.decidedAt = clock()
                    events(.committed(segment))
                    await inbox.put(segment)
                }
                await inbox.finish()
                return
            }
            guard now - lastHop >= config.hop else {
                try? await Task.sleep(for: .milliseconds(30))
                continue
            }
            lastHop = now
            guard vad.lastSpeech > segmenter.mark else { continue }  // nothing said since the last commit

            let start = segmenter.windowStart()
            let samples = buffer.read(Int(start * 16_000), heard)
            do {
                let words = segmenter.newWords(try await recognizer.transcribe(samples, offset: start))
                let silence = vad.silence(at: now)
                for var segment in await segmenter.step(now: now, words: words, silence: silence) {
                    segment.decidedAt = clock()
                    events(.committed(segment))
                    await inbox.put(segment)
                }
                events(.hearing(segmenter.pending.map(\.text).joined(separator: " ")))
                if words.isEmpty && silence >= segmenter.longPauseThreshold() { segmenter.advanceIdle(now: now) }
            } catch {
                events(.failed("Speech recognition: \(error.localizedDescription)"))
            }
            buffer.drop(before: Int((segmenter.windowStart() - 1) * 16_000))  // keep a second spare
        }
    }

    // MARK: interpreting

    private func interpret(_ speaker: Speaker, _ events: @Sendable (PipelineEvent) -> Void) async {
        while !Task.isCancelled, let waiting = await inbox.takeAll() {
            do {
                // Everything waiting goes as one: what the gate turns away set
                // aside, the rest merged into a single translation.
                var foreign: [Segment] = []
                for segment in waiting {
                    if let why = try await linguist.gate(segment.text) {
                        if why == .english { await linguist.remember(segment.text) }
                        events(.silent(index: segment.index, why, translation: nil))
                    } else {
                        foreign.append(segment)
                    }
                }
                guard !foreign.isEmpty else { continue }
                let piece = Segment.combine(foreign)
                let brief = backlog?.brief(speaker.backlog) ?? false
                let translation = try await linguist.translate(piece.text, brief: brief)
                if echoes(piece.text, translation) {
                    events(.silent(index: piece.index, .echo, translation: translation))
                    continue
                }
                let pace = backlog?.pace(speaker.backlog) ?? 1
                let start = speaker.play(try voice.speak(translation, pace: pace))
                let ends = piece.parts.isEmpty ? [piece.end] : piece.parts
                events(.interpreted(indices: foreign.map(\.index), translation: translation, playStart: start,
                                    lags: ends.map { start - $0 }, brief: brief, pace: pace))
            } catch {
                events(.failed("Interpreting: \(error.localizedDescription)"))
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
        waiter?.resume(returning: nil)
        waiter = nil
    }

    /// No more is coming: hand over what is waiting, then nothing.
    func finish() {
        finishing = true
        if items.isEmpty { close() }
    }
}
