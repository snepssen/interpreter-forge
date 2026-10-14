import Foundation
import OnnxRuntimeBindings

/// A Piper voice, for saying translations aloud.
///
/// Leaner than voice-forge's `VoiceEngine`, whose expression and timing layer
/// is that app's subject and not this one's. The same graph, the same id layout
/// (`^`, then each phoneme and a blank, then `$`), and for a voice-forge voice
/// its `vf_duration_factors` input fed ones, which reproduces the stock voice
/// exactly. `pace` divides the length scale: the graph rounds each phoneme up to
/// a whole frame, so it delivers about half of a small request (x1.1 gives
/// x1.05) and most of a large one (x1.4 gives x1.35), as measured in Python.
///
/// A polyglot voice (voice-polyglot; its config carries a "polyglot" block)
/// speaks `language`: text goes through `Polyphon`, the corrected espeak-ng it
/// was trained through, one `^`...`$` run per sentence as in its training
/// data, and each language at its own length scale. Its Suno-made languages
/// were read faster than its English, and the scales, picked by ear, even
/// them out.
public final class Voice: @unchecked Sendable {
    struct Config: Decodable {
        struct Audio: Decodable { var sample_rate: Int }
        struct Espeak: Decodable { var voice: String }
        struct Inference: Decodable { var noise_scale: Double; var length_scale: Double; var noise_w: Double }
        var audio: Audio
        var espeak: Espeak
        var inference: Inference
        var phoneme_id_map: [String: [Int]]
        var polyglot: Polyglot?
    }
    struct Polyglot: Decodable {
        var languages: [String]
        var length_scale: [String: Double]?
    }

    public enum Failure: LocalizedError {
        case noRuntime, noOutput
        public var errorDescription: String? {
            switch self {
            case .noRuntime: "The ONNX runtime failed to start."
            case .noOutput: "The voice produced no audio."
            }
        }
    }

    public let sampleRate: Double
    private let config: Config
    private let session: ORTSession
    private let phonemizer: EspeakPhonemizer
    private let espeakData: URL
    private var phonemizers: [String: EspeakPhonemizer] = [:]
    private var speaking = "en"
    private let takesFactors: Bool
    private let lock = NSLock()  // one ONNX run and one espeak call at a time
    private nonisolated(unsafe) static let env = try? ORTEnv(loggingLevel: .warning)

    public init(model: URL, espeakData: URL) throws {
        guard let env = Self.env else { throw Failure.noRuntime }
        let configURL = model.deletingPathExtension().appendingPathExtension("onnx.json")
        config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        session = try ORTSession(env: env, modelPath: model.path, sessionOptions: nil)
        phonemizer = try EspeakPhonemizer(dataDirectory: espeakData, voice: config.espeak.voice)
        takesFactors = (try? session.inputNames())?.contains("vf_duration_factors") ?? false
        sampleRate = Double(config.audio.sample_rate)
        self.espeakData = espeakData
    }

    /// The languages it was trained on: a polyglot voice's eight, else English.
    public var languages: [String] { config.polyglot?.languages ?? ["en"] }
    public var isPolyglot: Bool { config.polyglot != nil }

    /// What `speak` speaks. A language outside `languages` is read through
    /// plain espeak-ng, if espeak-ng has it: untrained, and it sounds it.
    public var language: String {
        get { lock.withLock { speaking } }
        set { lock.withLock { speaking = newValue } }
    }

    /// Mono samples at `sampleRate`, peak-normalised to 0.9.
    public func speak(_ text: String, pace: Double = 1) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var scale = config.inference.length_scale
        let ids: [Int]
        if let polyglot = config.polyglot {
            let espeak = try phonemizer(for: speaking)
            ids = Polyphon.ids(try Polyphon.sentences(text, language: speaking, espeak: espeak), map: config.phoneme_id_map)
            scale *= polyglot.length_scale?[speaking] ?? 1
        } else {
            ids = phonemeIDs(try phonemizer.phonemize(text))
        }
        guard ids.count > 3 else { return [] }
        var samples = try infer(ids, lengthScale: scale / pace)
        if let peak = samples.map(abs).max(), peak > 1e-8 {
            let gain = 0.9 / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return samples
    }

    /// Polyphon's ids for `text` in `language`, without speaking it.
    func polyglotIDs(_ text: String, language: String) throws -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return Polyphon.ids(try Polyphon.sentences(text, language: language, espeak: try phonemizer(for: language)),
                            map: config.phoneme_id_map)
    }

    /// One espeak-ng voice per language, made on first use. Under `lock`.
    private func phonemizer(for language: String) throws -> EspeakPhonemizer {
        if let made = phonemizers[language] { return made }
        let made = try EspeakPhonemizer(dataDirectory: espeakData, voice: Polyphon.espeakVoice(language))
        phonemizers[language] = made
        return made
    }

    private func phonemeIDs(_ phonemes: String) -> [Int] {
        let map = config.phoneme_id_map
        let pad = map["_"] ?? []
        var ids = (map["^"] ?? []) + pad
        for scalar in phonemes.unicodeScalars {
            guard let id = map[String(scalar)] else { continue }
            ids += id + pad
        }
        return ids + (map["$"] ?? [])
    }

    private func infer(_ ids: [Int], lengthScale: Double) throws -> [Float] {
        func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
            let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
        }
        var inputs = [
            "input": try tensor(ids.map { Int64($0) }, .int64, [1, ids.count]),
            "input_lengths": try tensor([Int64(ids.count)], .int64, [1]),
            // The model's order: noise, length, noise_w.
            "scales": try tensor([Float(config.inference.noise_scale), Float(lengthScale),
                                  Float(config.inference.noise_w)], .float, [3]),
        ]
        if takesFactors {
            inputs["vf_duration_factors"] = try tensor([Float](repeating: 1, count: ids.count), .float, [1, 1, ids.count])
        }
        let outputs = try session.run(withInputs: inputs, outputNames: ["output"], runOptions: nil)
        guard let data = try outputs["output"]?.tensorData() as Data? else { throw Failure.noOutput }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
