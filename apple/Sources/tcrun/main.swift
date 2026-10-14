// A recording through the Swift live pipeline at the pace it was spoken, for
// measuring what the app does without a microphone: the same loop, the same
// models, the same contention. The Python rig's `live --from`, in Swift.
//
//   tcrun <audio> [--model translategemma-4b-it-4bit] [--languages pl,hu,nl]   (default: any language)
//         [--into en]   (the listener's language, default English) [--summarise] [--out runs/swift-<name>]
import AVFoundation
import FluidAudio
import Foundation
import InterpreterCore
import InterpreterEngine

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let target = option("--into") ?? "en"
let summarise = args.contains("--summarise")
args.removeAll { $0 == "--summarise" }
let languages = (option("--languages") ?? "").split(separator: ",").map(String.init).filter { $0 != target }
let modelID = option("--model") ?? ModelCatalog.recommended.id
let recognitionID = option("--recognition") ?? RecognitionModel.parakeetUltra.rawValue
let outOption = option("--out")
guard let input = args.first else {
    print("usage: tcrun <audio> [--recognition parakeet-ultra|whisper-large-v3-v20240930-626mb] [--languages pl,hu,nl] [--into en] [--out dir]")
    exit(2)
}
let inputURL = URL(fileURLWithPath: input)
let out = URL(fileURLWithPath: outOption ?? "runs/swift-\(inputURL.deletingPathExtension().lastPathComponent)")

func info(_ message: String) { FileHandle.standardError.write(Data("· \(message)\n".utf8)) }

let samples = try AudioConverter().resampleAudioFile(inputURL)
info(String(format: "%@: %.1f s", inputURL.lastPathComponent, Double(samples.count) / 16_000))
guard let model = ModelCatalog.model(modelID), let modelURL = ModelStore.location(of: model),
      let voiceURL = Resources.voice, let espeak = Resources.espeakData, let vad = Resources.vad else {
    print("missing: translation model \(modelID) (one of \(ModelCatalog.translation.map(\.id))), voice \(Resources.voice != nil), VAD \(Resources.vad != nil)")
    exit(1)
}
info("loading")
guard let recognition = RecognitionModel(rawValue: recognitionID) else {
    info("unknown recognition model: \(recognitionID)")
    exit(2)
}
let recognizer = try await Recognizer.load(model: recognition, languages: languages)
info("recognising with \(recognition.name)")
let linguist = try await Linguist(model: model, at: modelURL, languages: languages, target: target)
await linguist.setRecognitionModel(recognition)
info("translating with \(model.name)" + (model.judges ? "" : ", cutting without a judge"))
let voice = try Voice(model: voiceURL, espeakData: espeak)
voice.language = target
info("speaking \(target) with \(voice.isPolyglot ? "the polyglot voice" : "the English voice")")
try await linguist.warmUp()

final class Tally: @unchecked Sendable {
    let lock = NSLock()
    var lags: [Double] = []
    var silent: [Silence: Int] = [:]
    var texts: [Int: String] = [:]
}
let tally = Tally()

info("playing in real time")
let pipeline = Pipeline(recognizer: recognizer, linguist: linguist, voice: voice, vad: vad)
pipeline.summarises = summarise
try pipeline.start(source: Recording(samples), speaker: nil, audible: false) { event in
    tally.lock.withLock {
        switch event {
        case .committed(let s):
            tally.texts[s.index] = s.text
            print(String(format: "[%6.2f–%6.2f] %-8@ │ %@", s.start, s.end, s.reason, s.text))
        case .silent(let index, let why, let detail):
            tally.silent[why, default: 0] += 1
            print("  #\(index) \(why.rawValue), not spoken")
            if why == .unclear, let detail { print("    \(detail)") }
        case .interpreted(let indices, let translation, let start, let lags, let brief, let pace):
            tally.lags += lags
            let marks = (brief ? " [brief]" : "") + (pace > 1 ? String(format: " [x%.2f]", pace) : "")
            print(String(format: "  #%@ plays %6.2fs lag %4.1fs%@ → %@", indices.map(String.init).joined(separator: "+"),
                         start, lags.max() ?? 0, marks, translation))
        case .failed(let why):
            print("  ! \(why)")
        case .hearing:
            break
        }
    }
}
await pipeline.finish()
if let failure = pipeline.failure {
    info("run failed: \(failure)")
    exit(1)
}

let lags = tally.lags.sorted()
if !lags.isEmpty {
    print(String(format: "\nlag           median %.1f s, max %.1f s over %d pieces", lags[lags.count / 2], lags.last!, lags.count))
}
print("not spoken    \(tally.silent[.understood] ?? 0) already \(target), \(tally.silent[.echo] ?? 0) echoes, \(tally.silent[.language] ?? 0) misheard")

// The listen-back: left the speaker, right the interpreter, where it would have played.
if let speaker = pipeline.speaker {
    let rate = speaker.sampleRate
    let left = stride(from: 0.0, to: Double(samples.count - 1), by: 16_000 / rate).map { x -> Float in
        let i = Int(x)
        return samples[i] + (samples[min(i + 1, samples.count - 1)] - samples[i]) * Float(x - Double(i))
    }
    let length = max(left.count, speaker.placed.map { Int($0.start * rate) + $0.samples.count }.max() ?? 0)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
    pcm.frameLength = AVAudioFrameCount(length)
    let channels = pcm.floatChannelData!
    for i in 0..<length { channels[0][i] = i < left.count ? left[i] : 0; channels[1][i] = 0 }
    for (start, clip) in speaker.placed {
        let at = Int(start * rate)
        for (i, value) in clip.enumerated() where at + i < length { channels[1][at + i] += value }
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let file = try AVAudioFile(forWriting: out.appending(path: "listen.wav"), settings: format.settings)
    try file.write(from: pcm)
    info("wrote \(out.path)/listen.wav (L: speaker, R: interpreter)")
}
