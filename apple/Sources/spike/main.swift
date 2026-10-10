// Proves the native stack before anything is built on it: Parakeet through
// FluidAudio, Qwen through MLX Swift, both on this Mac, timed.
import FluidAudio
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func now() -> Double { Date().timeIntervalSinceReferenceDate }

// --- ASR -------------------------------------------------------------------
var t = now()
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asr = AsrManager(config: .default)
try await asr.loadModels(models)
print(String(format: "parakeet loaded in %.1f s", now() - t))

let audio = try AudioConverter().resampleAudioFile(root.appending(path: "samples/de_halting.wav"))
for seconds in [2.0, 5.0, 10.0, 15.0] {
    let window = Array(audio.prefix(Int(seconds * 16_000)))
    var state = TdtDecoderState.make()
    _ = try await asr.transcribe(window, decoderState: &state, language: .polish)  // warm
    state = TdtDecoderState.make()
    t = now()
    let result = try await asr.transcribe(window, decoderState: &state, language: .polish)
    let ms = (now() - t) * 1000
    let words = buildWordTimings(from: result.tokenTimings ?? [])
    print(String(format: "%4.0f s window: %4.0f ms  %@", seconds, ms, result.text))
    if seconds == 5.0 {
        print("   words:", words.map { String(format: "%@ %.2f–%.2f", $0.word, $0.startTime, $0.endTime) }.joined(separator: ", "))
    }
}

// --- LLM -------------------------------------------------------------------
t = now()
let container = try await loadModelContainer(
    from: root.appending(path: "models/qwen3-4b-instruct-2507-4bit"), using: #huggingFaceTokenizerLoader())
print(String(format: "qwen loaded in %.1f s", now() - t))
let messages: [[String: String]] = [
    ["role": "system", "content": "You are a live interpreter working into English. Reply with only the English translation."],
    ["role": "user", "content": "Translate: Der Grund ist, dass der Zug aus München wegen Bauarbeiten ausfällt."],
]
try await container.perform { context in
    let tokens = try context.tokenizer.applyChatTemplate(messages: messages)
    let cache = try context.model.newCache(parameters: nil)
    for run in 0..<2 {
        let t = now()
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model,
                                         cache: cache, parameters: GenerateParameters(temperature: 0))
        var out: [Int] = []
        while let token = iterator.next() {
            if token == context.tokenizer.eosTokenId || context.configuration.extraEOSTokens.contains(context.tokenizer.convertIdToToken(token) ?? "") { break }
            out.append(token)
        }
        print(String(format: "translate run %d: %.0f ms  → %@  (cache %d tokens, trimmable %@)", run,
                     (now() - t) * 1000, context.tokenizer.decode(tokenIds: out), cache[0].offset,
                     canTrimPromptCache(cache) ? "yes" : "no"))
        _ = trimPromptCache(cache, numTokens: cache[0].offset)
    }
}
