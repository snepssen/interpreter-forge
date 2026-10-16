import AVFoundation
import Foundation
import InterpreterEngine

// tcasr MODEL INPUT_DIRECTORY OUTPUT.jsonl
// Each WAV has a matching reference .txt. No language is forced or hinted.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3, let model = RecognitionModel(rawValue: args[0]) else {
    fatalError("usage: tcasr MODEL INPUT_DIRECTORY OUTPUT.jsonl")
}
let folder = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
guard !FileManager.default.fileExists(atPath: outputURL.path) else {
    fatalError("refusing to overwrite existing evidence")
}
FileManager.default.createFile(atPath: outputURL.path, contents: nil)
let output = try FileHandle(forWritingTo: outputURL)
let loading = Date()
let recognizer = try await Recognizer.load(model: model, languages: [])
let loadSeconds = Date().timeIntervalSince(loading)
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else { fatalError("no WAV files") }
for url in files {
    let file = try AVAudioFile(forReading: url)
    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 4096))!
    var supplied = false
    var error: NSError?
    converter.convert(to: buffer, error: &error) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true; status.pointee = .haveData; return input
    }
    if let error { throw error }
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let started = Date()
    let words = try await recognizer.transcribe(samples, offset: 0)
    let record: [String: Any] = [
        "file": url.lastPathComponent, "model": model.rawValue,
        "reference": try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8),
        "hypothesis": words.map(\.text).joined(separator: " "),
        "audio_seconds": Double(samples.count) / 16_000,
        "recognition_seconds": Date().timeIntervalSince(started), "load_seconds": loadSeconds,
        "words": words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
    ]
    try output.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
    try output.write(contentsOf: Data([10]))
    try output.synchronize()
    print("\(model.rawValue) \(url.lastPathComponent): \(words.map(\.text).joined(separator: " "))")
}
try output.close()
