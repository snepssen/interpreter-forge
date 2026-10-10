import AVFoundation
import Foundation
import InterpreterCore
import Observation

/// Everything the app shows and controls, on the main actor. The Mac app and,
/// later, the iPhone app are views of this.
@MainActor @Observable
public final class LiveSession {
    public enum Phase: Equatable {
        case idle
        case loading(String)
        case ready
        case live
        case failed(String)
    }

    /// One piece of speech and what became of it.
    public struct Line: Identifiable, Equatable {
        public let id: Int
        public var source: String
        public var reason: String
        public var translation: String?
        public var silence: Silence?
        public var lag: Double?
        public var brief = false
        public var pace = 1.0
        public var at: Date
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lines: [Line] = []
    public private(set) var hearing = ""
    public private(set) var level: Float = 0
    public private(set) var notice: String?

    /// English alone means any language: everything that isn't English is
    /// translated. Naming languages restricts to them, and anything else is
    /// taken as misheard, which helps where Polish keeps coming out as Russian
    /// but would silence a Romanian guest. English is understood by the
    /// listener and kept as context, not spoken. Remembered between launches.
    public var languages: [String] = UserDefaults.standard.stringArray(forKey: "languages") ?? ["en"] {
        didSet {
            UserDefaults.standard.set(languages, forKey: "languages")
            let languages = languages
            Task { [recognizer, linguist] in
                await recognizer?.setLanguages(languages)
                await linguist?.setLanguages(languages)
            }
        }
    }

    public var anyLanguage: Bool { !languages.contains { $0 != "en" } }
    /// Device names (or part of them); nil for the system's.
    public var microphone: String?
    public var speaker: String?

    private var recognizer: Recognizer?
    private var linguist: Linguist?
    private var voice: Voice?
    private var pipeline: Pipeline?
    private var meter: Task<Void, Never>?

    public init() {}

    public var isLive: Bool { phase == .live }

    /// Load the three models; the first run downloads Parakeet (a few hundred MB).
    public func prepare() async {
        guard phase == .idle || phase.isFailure else { return }
        do {
            if Resources.translationModel == nil { phase = .loading("Downloading the translation model…") }
            let model = try await ModelStore.translationModel { fraction in
                Task { @MainActor in
                    self.phase = .loading("Downloading the translation model… \(Int(fraction * 100))% of 2.3 GB")
                }
            }
            guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else {
                throw Problem("No voice. Build with build.sh, or keep voice-forge beside translate-core.")
            }
            phase = .loading("Loading speech recognition…")
            recognizer = try await Recognizer.load(languages: languages) { fraction in
                Task { @MainActor in
                    if case .loading = self.phase, fraction < 1 {
                        self.phase = .loading("Downloading speech recognition… \(Int(fraction * 100))%")
                    }
                }
            }
            phase = .loading("Loading the translation model…")
            linguist = try await Linguist(model: model, languages: languages)
            phase = .loading("Loading the voice…")
            voice = try Voice(model: voiceURL, espeakData: espeak)
            phase = .loading("Warming up…")
            try await linguist?.warmUp()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func start() async {
        if phase != .ready { await prepare() }
        guard phase == .ready, let recognizer, let linguist, let voice, let vad = Resources.vad else {
            if Resources.vad == nil { phase = .failed("No voice activity model (models/silero_vad.onnx).") }
            return
        }
        guard await Self.microphoneAllowed() else {
            notice = "Interpreter needs the microphone: allow it in System Settings → Privacy & Security → Microphone, then press Live."
            return
        }
        let pipeline = Pipeline(recognizer: recognizer, linguist: linguist, voice: voice, vad: vad)
        do {
            try pipeline.start(microphone: microphone, speaker: speaker) { event in
                Task { @MainActor in self.apply(event) }
            }
        } catch {
            notice = "Couldn't open the audio: \(error.localizedDescription)"
            return
        }
        self.pipeline = pipeline
        notice = nil
        phase = .live
        meter = Task { [weak self] in
            while !Task.isCancelled {
                self?.level = pipeline.level
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Ask before the audio engine touches the input: until access is granted the
    /// input has no format, and AVAudioEngine raises on it.
    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func stop() {
        pipeline?.stop()
        pipeline = nil
        meter?.cancel()
        level = 0
        hearing = ""
        if phase == .live { phase = .ready }
    }

    public func clear() { lines.removeAll() }

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .hearing(let text):
            hearing = text
        case .committed(let segment):
            lines.append(Line(id: segment.index, source: segment.text, reason: segment.reason, at: Date()))
        case .silent(let index, let why, let translation):
            update(index) {
                $0.silence = why
                $0.translation = translation
            }
        case .interpreted(let indices, let translation, _, let lags, let brief, let pace):
            // Merged pieces become one line, under the first.
            let merged = lines.filter { indices.dropFirst().contains($0.id) }.map(\.source)
            lines.removeAll { indices.dropFirst().contains($0.id) }
            update(indices[0]) {
                $0.source = ([$0.source] + merged).joined(separator: " ")
                $0.translation = translation
                $0.lag = lags.max()
                $0.brief = brief
                $0.pace = pace
            }
        case .failed(let message):
            notice = message
        }
    }

    private func update(_ index: Int, _ change: (inout Line) -> Void) {
        guard let i = lines.lastIndex(where: { $0.id == index }) else { return }
        change(&lines[i])
    }
}

extension LiveSession.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

struct Problem: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
