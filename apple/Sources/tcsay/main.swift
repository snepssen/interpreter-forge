// Test speech from the app's own voice: the polyglot snepssen, through the
// same Voice and Polyphon the interpreter speaks with. What it says can then
// be played through tcrun and interpreted into another language, which also
// shows how legible the voice is to speech recognition.
//
//   tcsay --lang hu --out samples/snepssen/hu_x.wav "Szia. [[slnc 900]] Hogy vagy?"
//
// [[slnc ms]] is a silence, as in macOS `say`, so hesitation can be written
// in; each stretch between silences is rendered on its own, as a speaker
// starts again after a pause.
import Foundation
import InterpreterEngine

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let language = option("--lang") ?? "en"
guard let out = option("--out"), let text = args.first else {
    print("usage: tcsay --lang hu --out file.wav \"text, with [[slnc 900]] for a pause\"")
    exit(2)
}
guard let model = Resources.polyglotVoice, let espeak = Resources.espeakData else {
    print("missing: the polyglot voice (voice-polyglot beside interpreter-forge) or espeak-ng data")
    exit(1)
}
let voice = try Voice(model: model, espeakData: espeak)
voice.language = language

// Text and silences, in order.
var samples: [Float] = []
let rate = voice.sampleRate
var rest = Substring(text)
while !rest.isEmpty {
    let marker = rest.range(of: "[[slnc ")
    let piece = rest[..<(marker?.lowerBound ?? rest.endIndex)].trimmingCharacters(in: .whitespaces)
    if !piece.isEmpty { samples += try voice.speak(piece).map { $0 * 0.8 } }
    guard let marker, let close = rest[marker.upperBound...].range(of: "]]") else { break }
    let ms = Double(rest[marker.upperBound..<close.lowerBound]) ?? 0
    samples += [Float](repeating: 0, count: Int(ms / 1000 * rate))
    rest = rest[close.upperBound...]
}
samples += [Float](repeating: 0, count: Int(0.5 * rate))

// 16-bit mono WAV.
var data = Data()
@MainActor func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count * 2))
data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
data.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count * 2))
for s in pcm { put(s) }
let url = URL(fileURLWithPath: out)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: url)
// What was said, without the silences: for scoring what recognition heard.
let said = text.replacing(/\s*\[\[slnc \d+\]\]\s*/, with: " ")
try said.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
print(String(format: "%@  %.1f s  (%@)", out, Double(samples.count) / rate, language))
