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
        /// No translation model downloaded yet: the picker's turn.
        case choosingModel
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
        /// Who spoke it, when the detector is sure: for the line's language chip.
        public var language: String?
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lines: [Line] = []
    public private(set) var hearing = ""
    public private(set) var level: Float = 0
    /// The interpreter's voice is playing in the headphones right now.
    public private(set) var speaking = false
    public private(set) var notice: String?

    /// The listener's language alone means any language: everything that
    /// isn't theirs is translated. Naming languages restricts to them, and
    /// anything else is taken as misheard, which helps where Polish keeps
    /// coming out as Russian but would silence a Romanian guest. The
    /// listener's own language is understood and kept as context, not
    /// spoken; it is always in this list, the marker the filter is read
    /// against. Remembered between launches.
    public var languages: [String] = UserDefaults.standard.stringArray(forKey: "languages") ?? ["en"] {
        didSet {
            UserDefaults.standard.set(languages, forKey: "languages")
            applyLanguages()
        }
    }

    /// The language the listener hears: everything is interpreted into it and
    /// the voice speaks it. One the voice was trained on, unless untrained
    /// languages are allowed in Settings. Remembered.
    public var target: String = UserDefaults.standard.string(forKey: "target") ?? "en" {
        didSet {
            guard target != oldValue else { return }
            UserDefaults.standard.set(target, forKey: "target")
            // The new language takes the old one's place as the marker; one
            // that was named as spoken here is now the listener's own.
            languages = [target] + languages.filter { $0 != oldValue && $0 != target }
        }
    }

    /// Offer the languages the voice was not trained on: it reads them through
    /// plain espeak-ng, with an accent and no corrections. Off unless chosen.
    public var untrainedLanguages: Bool = UserDefaults.standard.bool(forKey: "untrainedLanguages") {
        didSet {
            UserDefaults.standard.set(untrainedLanguages, forKey: "untrainedLanguages")
            if !untrainedLanguages && !Self.trainedTargets.contains(target) { target = "en" }
        }
    }

    /// What the voice speaks well, in the order offered.
    public static let trainedTargets = Polyphon.trained
    /// What it can be asked to speak beyond those: Parakeet's European
    /// languages, every one of which espeak-ng reads.
    public static let untrainedTargets = Languages.names.keys.filter { !Polyphon.trained.contains($0) }
        .sorted { Languages.names[$0]! < Languages.names[$1]! }
    public var targetChoices: [String] {
        Self.trainedTargets + (untrainedLanguages ? Self.untrainedTargets : [])
    }
    public func isTrained(_ code: String) -> Bool { Self.trainedTargets.contains(code) }
    public func languageName(_ code: String) -> String {
        Languages.names[code] ?? availableLanguages[code] ?? code
    }

    /// The languages spoken here, if restricted; empty for any.
    public var spoken: [String] { languages.filter { $0 != target } }
    public var anyLanguage: Bool { spoken.isEmpty }

    private func applyLanguages() {
        let (spoken, target) = (spoken, target)
        voice?.language = target
        Task { [recognizer, linguist] in
            await recognizer?.setLanguages(spoken)
            await linguist?.setLanguages(spoken, target: target)
        }
    }
    /// The translation model in use, chosen in the picker or the manager; remembered.
    public private(set) var translationModel: TranslationModel? =
        ModelCatalog.model(UserDefaults.standard.string(forKey: "translationModel"))
    public private(set) var recognitionModel =
        RecognitionModel(rawValue: UserDefaults.standard.string(forKey: "recognitionModel") ?? "") ?? .parakeetUltra
    public var availableLanguages: [String: String] { recognitionModel.languageNames }
    public func languageList(_ codes: [String]) -> String {
        Languages.list(codes, names: availableLanguages)
    }
    /// Downloads under way, by model id, from 0 to 1.
    public private(set) var downloads: [String: Double] = [:]
    /// Bumped when models come or go, so views listing them look again.
    public private(set) var storeChanges = 0

    /// How loud the interpreter speaks, from 0 to 1. Remembered.
    public var voiceVolume: Double = UserDefaults.standard.object(forKey: "voiceVolume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(voiceVolume, forKey: "voiceVolume")
            applyVoice()
        }
    }

    /// Translations on screen only, not spoken: for when there are no
    /// headphones and the phone's speaker would talk over the room. Remembered.
    public var captionsOnly: Bool = UserDefaults.standard.bool(forKey: "captionsOnly") {
        didSet {
            UserDefaults.standard.set(captionsOnly, forKey: "captionsOnly")
            applyVoice()
        }
    }

    /// Say the gist instead of the whole translation when falling behind:
    /// for following a long story as it goes rather than hearing all of it.
    /// Needs a model that takes instructions. Off unless chosen; remembered.
    public var summarises: Bool = UserDefaults.standard.bool(forKey: "summarises") {
        didSet {
            UserDefaults.standard.set(summarises, forKey: "summarises")
            applyVoice()
        }
    }

    private func applyVoice() {
        pipeline?.summarises = summarises
        pipeline?.speaks = !captionsOnly
        pipeline?.speaker?.volume = captionsOnly ? 0 : Float(voiceVolume)
    }

    /// Device names (or part of them); nil for the system's. On the iPhone the
    /// microphone is a PhoneAudio.Input. Remembered.
    public var microphone: String? = UserDefaults.standard.string(forKey: "microphone") {
        didSet { UserDefaults.standard.set(microphone, forKey: "microphone") }
    }
    public var speaker: String? = UserDefaults.standard.string(forKey: "speaker") {
        didSet { UserDefaults.standard.set(speaker, forKey: "speaker") }
    }
    /// The microphone the last session actually used, and in what mode.
    public private(set) var inputDescription: String?

    private var recognizer: Recognizer?
    private var linguist: Linguist?
    private var voice: Voice?
    private var pipeline: Pipeline?
    private var meter: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var generation = UUID()
    private var preparationID: UUID?
    private var preparationTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownID = UUID()
    private var active = true
    private var windows: Set<UUID> = []
    private var starting = false
    private var lineIDs: [Int: Int] = [:]
    private var nextLineID = 0
    private var sessionStart = 0
    public var isBusy: Bool { preparationID != nil || starting || shutdownTask != nil }
    private var audioObservers: [NSObjectProtocol] = []

    public init() {}

    public var isLive: Bool { phase == .live }

    /// Load recognition, translation and voice; download recognition if needed.
    public func prepare() async {
        let generation = self.generation
        await shutdownTask?.value
        guard generation == self.generation, active, !Task.isCancelled, preparationID == nil else { return }
        guard phase == .idle || phase == .choosingModel || phase.isFailure else { return }
        guard let model = translationModel, let modelURL = ModelStore.location(of: model) else {
            phase = .choosingModel
            return
        }
        let preparation = UUID()
        preparationID = preparation
        let loading = Task { await load(model, at: modelURL, preparation: preparation) }
        preparationTask = loading
        await loading.value
        if preparationID == preparation {
            preparationID = nil
            preparationTask = nil
        }
    }

    private func load(_ model: TranslationModel, at modelURL: URL, preparation: UUID) async {
        do {
            try Task.checkCancellation()
            guard let voiceURL = Resources.voice, let espeak = Resources.espeakData else {
                throw Problem("No voice. Build with build.sh, or keep voice-polyglot and voice-forge beside translate-core.")
            }
            if recognizer == nil {
                phase = .loading("Loading speech recognition…")
                let loaded = try await Recognizer.load(model: recognitionModel, languages: spoken) { fraction in
                    Task { @MainActor in
                        if self.active, self.preparationID == preparation, self.recognizer == nil, case .loading = self.phase {
                            self.phase = .loading(fraction < 1
                                ? "Downloading speech recognition… \(Int(fraction * 100))%"
                                : "Loading speech recognition…")
                        }
                    }
                }
                try Task.checkCancellation()
                recognizer = loaded
            }
            try Task.checkCancellation()
            if linguist?.model != model {
                linguist = nil  // one translation model in memory at a time
                phase = .loading("Loading \(model.name)…")
                linguist = try await Linguist(model: model, at: modelURL, languages: spoken, target: target)
            }
            try Task.checkCancellation()
            if voice == nil {
                phase = .loading("Loading the voice…")
                voice = try Voice(model: voiceURL, espeakData: espeak)
            }
            voice?.language = target
            try Task.checkCancellation()
            phase = .loading("Warming up…")
            try await linguist?.warmUp()
            await recognizer?.setLanguages(spoken)
            await linguist?.setLanguages(spoken, target: target)
            await linguist?.setRecognitionModel(recognitionModel)
            try Task.checkCancellation()
            storeChanges += 1
            phase = .ready
        } catch {
            phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
        }
    }

    public func start() async {
        guard active, !starting, !isLive, preparationID == nil else { return }
        let generation = self.generation
        await shutdownTask?.value
        guard generation == self.generation, active, !Task.isCancelled, !starting else { return }
        starting = true
        defer { starting = false }
        if phase != .ready { await prepare() }
        guard generation == self.generation, active, !Task.isCancelled else { return }
        guard phase == .ready, let recognizer, let linguist, let voice, let vad = Resources.vad else {
            if Resources.vad == nil { phase = .failed("No voice activity model (models/silero_vad.onnx).") }
            return
        }
        let allowed = await Self.microphoneAllowed()
        guard generation == self.generation else { return }
        guard allowed else {
            notice = "Interpreter needs the microphone: allow it in System Settings → Privacy & Security → Microphone, then press Live."
            return
        }
        await linguist.forget()
        guard generation == self.generation else { return }
        let pipeline = Pipeline(recognizer: recognizer, linguist: linguist, voice: voice, vad: vad)
        let (events, continuation) = AsyncStream<PipelineEvent>.makeStream()
        do {
            try pipeline.start(microphone: microphone, speaker: speaker) { event in
                continuation.yield(event)
            }
        } catch {
            notice = "Couldn't open the audio: \(error.localizedDescription)"
            return
        }
        self.pipeline = pipeline
        applyVoice()
        beginTranscript()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
        notice = nil
        #if os(iOS)
        inputDescription = PhoneAudio.inputDescription
        if PhoneAudio.Input(microphone).usesHeadphones && !PhoneAudio.inputIsHeadphones {
            notice = "No headphone microphone is connected, so the iPhone's is listening."
        }
        #endif
        phase = .live
        observeAudioChanges()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                self?.level = pipeline.level
                self?.speaking = (pipeline.speaker?.backlog ?? 0) > 0.05
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

    // MARK: models

    /// Switch only while stopped. Release the old recognizer before downloading
    /// or loading another; no silent fallback when the chosen model fails.
    public func useRecognition(_ model: RecognitionModel) async {
        guard !isLive, !isBusy else { return }
        guard model != recognitionModel || recognizer == nil else { return }
        recognitionModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "recognitionModel")
        recognizer = nil
        let supported = model.supportedFilter(languages, keeping: target)
        if supported != languages {
            languages = supported
            notice = "The language filter now contains only languages supported by \(model.name)."
        }
        phase = .idle
        await prepare()
    }

    /// Fetch a model; progress shows in `downloads`. Use it straight away if
    /// none is in use yet.
    public func download(_ model: TranslationModel) async {
        guard downloads[model.id] == nil else { return }
        downloads[model.id] = 0
        defer {
            downloads[model.id] = nil
            storeChanges += 1
        }
        do {
            try await ModelStore.download(model) { fraction in
                Task { @MainActor in
                    if self.downloads[model.id] != nil { self.downloads[model.id] = fraction }
                }
            }
            if translationModel == nil || ModelStore.location(of: translationModel!) == nil { await use(model) }
        } catch {
            notice = "Couldn't download \(model.name): \(error.localizedDescription)"
        }
    }

    /// Switch the translation model; the old one leaves memory first.
    public func use(_ model: TranslationModel) async {
        guard !isBusy else { return }
        guard model != translationModel || linguist == nil else { return }
        if isLive { stop() }
        translationModel = model
        UserDefaults.standard.set(model.id, forKey: "translationModel")
        linguist = nil
        phase = .idle
        await prepare()
    }

    public func delete(_ model: TranslationModel) {
        guard !isBusy, downloads[model.id] == nil else { return }
        if model == translationModel {
            if isLive { stop() }
            linguist = nil
            translationModel = nil
            UserDefaults.standard.removeObject(forKey: "translationModel")
            phase = .choosingModel
        }
        do { try ModelStore.delete(model) } catch { notice = "Couldn't delete \(model.name): \(error.localizedDescription)" }
        storeChanges += 1
    }

    public func stop() {
        generation = UUID()
        preparationTask?.cancel()
        let previous = shutdownTask
        let loading = preparationTask
        let pipeline = self.pipeline
        if previous != nil || loading != nil || pipeline != nil {
            let shutdown = UUID()
            shutdownID = shutdown
            shutdownTask = Task { [weak self] in
                await previous?.value
                await loading?.value
                await pipeline?.finish()
                if self?.shutdownID == shutdown { self?.shutdownTask = nil }
            }
        }
        eventsTask?.cancel()
        eventsTask = nil
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        audioObservers.removeAll()
        pipeline?.stop()
        self.pipeline = nil
        meter?.cancel()
        meter = nil
        level = 0
        speaking = false
        hearing = ""
        if phase == .live { phase = .ready }
    }

    /// GPU translation is foreground-only on iOS. Cancel before the app enters
    /// the background, and drain old work before permitting another session.
    public func setActive(_ active: Bool) {
        self.active = active
        if !active {
            let interrupted = isLive || isBusy
            stop()
            if interrupted { notice = "Interpreter paused. Keep the app open and press Live to restart." }
        }
    }

    /// All Mac windows share this session. Capture ends when its last view closes.
    public func windowOpened(_ id: UUID) { windows.insert(id) }
    public func windowClosed(_ id: UUID) {
        guard windows.remove(id) != nil, windows.isEmpty else { return }
        stop()
    }

    /// Observe our own engines. Startup/category notifications are harmless
    /// while those engines are running and the active route remains unchanged.
    private func observeAudioChanges() {
        let generation = self.generation
        for engine in pipeline?.audioEngines ?? [] {
            audioObservers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.audioChanged(.engineConfiguration(owned: true, isRunning: engine.isRunning),
                                       generation: generation)
                }
            })
        }
        #if os(iOS)
        let route = PhoneAudio.routeState
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.audioChanged(.route(before: route, after: PhoneAudio.routeState), generation: generation)
            }
        })
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in self?.audioChanged(.interruption(began: began), generation: generation) }
        })
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioChanged(.mediaReset, generation: generation) }
        })
        #endif
    }

    private func audioChanged(_ change: AudioChange, generation: UUID) {
        guard isLive, self.generation == generation, change.requiresRestart else { return }
        stop()
        notice = "The audio route changed or was interrupted. Press Live to restart."
    }

    public func clear() { lines.removeAll() }

    func beginTranscript() {
        lineIDs.removeAll()
        sessionStart = nextLineID
    }

    /// A piece of this session is waiting for its translation.
    public var translating: Bool {
        isLive && lines.contains { $0.id >= sessionStart && $0.translation == nil && $0.silence == nil }
    }

    func apply(_ event: PipelineEvent) {
        switch event {
        case .hearing(let text):
            hearing = text
        case .committed(let segment):
            lineIDs[segment.index] = nextLineID
            lines.append(Line(id: nextLineID, source: segment.text, reason: segment.reason, at: Date(),
                              language: Self.language(of: segment.text)))
            nextLineID += 1
        case .silent(let index, let why, let translation):
            guard let id = lineIDs[index] else { return }
            update(id) {
                $0.silence = why
                $0.translation = translation
                if why == .understood { $0.language = self.target }
            }
        case .interpreted(let indices, let translation, _, let lags, let brief, let pace):
            let ids = indices.compactMap { lineIDs[$0] }
            guard let first = ids.first else { return }
            // Merged pieces become one line, under the first.
            let merged = lines.filter { ids.dropFirst().contains($0.id) }.map(\.source)
            lines.removeAll { ids.dropFirst().contains($0.id) }
            update(first) {
                $0.source = ([$0.source] + merged).joined(separator: " ")
                $0.language = Self.language(of: $0.source) ?? $0.language
                $0.translation = translation
                $0.lag = lags.max()
                $0.brief = brief
                $0.pace = pace
            }
        case .failed(let message):
            stop()
            phase = .failed(message)
            notice = message
        }
    }

    private static let detector = LanguageDetector()

    /// A label, not a decision: the linguist has its own, with context. Short
    /// replies ("Igen") get no chip rather than a wrong one.
    static func language(of text: String) -> String? {
        guard let guess = detector.guess(text), guess.confidence >= 0.6 else { return nil }
        return guess.code
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
