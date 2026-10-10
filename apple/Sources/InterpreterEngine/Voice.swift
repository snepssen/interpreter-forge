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
public final class Voice: @unchecked Sendable {
    struct Config: Decodable {
        struct Audio: Decodable { var sample_rate: Int }
        struct Espeak: Decodable { var voice: String }
        struct Inference: Decodable { var noise_scale: Double; var length_scale: Double; var noise_w: Double }
        var audio: Audio
        var espeak: Espeak
        var inference: Inference
        var phoneme_id_map: [String: [Int]]
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
    }

    /// Mono samples at `sampleRate`, peak-normalised to 0.9.
    public func speak(_ text: String, pace: Double = 1) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let ids = phonemeIDs(try phonemizer.phonemize(text))
        guard ids.count > 3 else { return [] }
        var samples = try infer(ids, lengthScale: config.inference.length_scale / pace)
        if let peak = samples.map(abs).max(), peak > 1e-8 {
            let gain = 0.9 / peak
            for i in samples.indices { samples[i] *= gain }
        }
        return samples
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
            var values = values
            let data = NSMutableData(bytes: &values, length: values.count * MemoryLayout<T>.stride)
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
