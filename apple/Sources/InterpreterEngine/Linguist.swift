import Foundation
import InterpreterCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Why a piece is not spoken.
public enum Silence: String, Sendable {
    case english  // already English: kept as context
    case language  // in no language expected here: speech recognition went astray
    case echo  // a "translation" that only repeats its source: garbled English
}

/// The one LLM, asked four things: translate this; can this be translated yet;
/// is this English; is this in a language spoken here. An actor, because MLX
/// is driven from one place at a time.
///
/// Every question keeps its own attention cache and each call reads only what
/// changed since the last one: on an M1 reading the prompt costs as much as
/// writing the answer (`translate.py`, `judge.py`).
public actor Linguist {
    private let context: ModelContext
    private let languages: [String]
    private let system: String
    private var history: [(source: String, target: String)] = []
    private let contextPieces = 3
    private var translator: PromptCache
    private var questions: [String: PromptCache] = [:]
    private let yes: [Int32]
    private let no: [Int32]

    public init(model directory: URL, languages: [String]) async throws {
        MLX.GPU.set(cacheLimit: 1 << 30)  // variable shapes otherwise grow it without bound
        let context = try await loadModel(from: directory, using: #huggingFaceTokenizerLoader())
        yes = Self.firstTokens(context.tokenizer, ["yes", "Yes", " yes", " Yes"])
        no = Self.firstTokens(context.tokenizer, ["no", "No", " no", " No"])
        translator = try PromptCache(context.model)
        self.context = context
        self.languages = languages
        let spoken = languages.filter { $0 != "en" }
        system = Prompts.translate + (spoken.isEmpty ? "" : Prompts.speakers(Languages.list(spoken)))
    }

    /// The first token of each spelling; the model's answer starts with one of them.
    private static func firstTokens(_ tokenizer: any MLXLMCommon.Tokenizer, _ words: [String]) -> [Int32] {
        Array(Set(words.compactMap { tokenizer.encode(text: $0, addSpecialTokens: false).first })).map(Int32.init)
    }

    // MARK: translation

    /// English for `text`; `brief` asks for the gist only, to catch up a backlog.
    public func translate(_ text: String, brief: Bool = false) throws -> String {
        let text = Clock.normalise(text)
        if history.count >= 2 * contextPieces { history.removeFirst(history.count - contextPieces) }
        var messages = [["role": "system", "content": system]]
        for (source, target) in history {
            messages.append(["role": "user", "content": Prompts.piece(source, brief: false)])
            messages.append(["role": "assistant", "content": target])
        }
        messages.append(["role": "user", "content": Prompts.piece(text, brief: brief)])
        let prompt = try context.tokenizer.applyChatTemplate(messages: messages)

        let fresh = translator.prepare(for: prompt)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model,
                                         cache: translator.kv, parameters: GenerateParameters(maxTokens: 256, temperature: 0))
        var produced: [Int] = []
        let stops = Set([context.tokenizer.eosTokenId].compactMap { $0 })
            .union(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
        while let token = iterator.next() {
            if stops.contains(token) { break }
            produced.append(token)
        }
        // The cache may run a token past what was kept; hold it to what we know.
        translator.settle(prompt + produced)

        var out = context.tokenizer.decode(tokenIds: produced).trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
        history.append((text, out))
        return out
    }

    /// Keep a piece that needed no translation as context for the ones that do.
    public func remember(_ text: String) { history.append((text, text)) }

    public func forget() { history.removeAll() }

    /// Read every question's instructions once, so the first real piece doesn't pay for it.
    public func warmUp() throws {
        _ = try translate("Hallo.")
        _ = try complete("Hallo")
        _ = try gate("Hallo, jak się masz?")
        forget()
    }

    // MARK: questions

    /// Can this be translated correctly now? Parakeet ends every window with a
    /// full stop, which says nothing about meaning, so that is stripped first.
    public func complete(_ text: String) throws -> Bool {
        var text = text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ".?!…".contains(last) { text.removeLast() }
        return try ask(Prompts.complete, text) >= 0.5
    }

    /// Before translating: does this piece need it? Dropping real speech is the
    /// worse mistake, so the text's own evidence is looked at before the model is
    /// asked: the model is sure garbled Hungarian is not Hungarian.
    public func gate(_ text: String) throws -> Silence? {
        // Two or more letters English doesn't use settle it without asking.
        let foreign = text.filter { $0.isLetter && !$0.isASCII }.count
        if foreign < 2, try ask(Prompts.english, text) >= 0.5 { return .english }
        guard !languages.isEmpty else { return nil }
        let verdict = try Languages.evidence(text, languages)
            ?? (ask(Prompts.expected(Languages.list(languages)), text) >= 0.5)
        return verdict ? nil : .language
    }

    /// How sure the model is that the answer is yes, between yes and no: one
    /// forward pass, the last position only.
    private func ask(_ instructions: String, _ text: String) throws -> Double {
        let messages = [["role": "system", "content": instructions], ["role": "user", "content": "\"\(text)\""]]
        let prompt = try context.tokenizer.applyChatTemplate(messages: messages)
        var cache = try questions[instructions] ?? PromptCache(context.model)
        let fresh = cache.prepare(for: prompt)
        let logits = context.model(LMInput.Text(tokens: MLXArray(fresh))[text: .newAxis], cache: cache.kv, state: nil)
            .logits[0, -1]
        cache.settle(prompt)
        questions[instructions] = cache
        let margin = logits[MLXArray(yes)].max() - logits[MLXArray(no)].max()
        return Double(sigmoid(margin).item(Float.self))
    }
}

/// An attention cache and the tokens it holds, reused across calls that share a prefix.
struct PromptCache {
    let kv: [KVCache]
    private(set) var tokens: [Int] = []

    init(_ model: any LanguageModel) throws {
        kv = try model.newCache(parameters: nil)
    }

    /// Trim back to what `prompt` shares with what is held; returns the part to read.
    mutating func prepare(for prompt: [Int]) -> [Int] {
        var keep = zip(tokens, prompt).prefix { $0 == $1 }.count
        keep = min(keep, prompt.count - 1)  // always read at least one token
        _ = trimPromptCache(kv, numTokens: (kv.first?.offset ?? 0) - keep)
        return Array(prompt[keep...])
    }

    /// After a call: the cache holds `held`, and nothing past it.
    mutating func settle(_ held: [Int]) {
        let extra = (kv.first?.offset ?? 0) - held.count
        if extra > 0 { _ = trimPromptCache(kv, numTokens: extra) }
        tokens = held
    }
}
