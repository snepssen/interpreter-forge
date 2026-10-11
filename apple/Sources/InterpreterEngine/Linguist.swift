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
    case unclear  // a reproduced quality problem: shown for clarification, not spoken
}

/// The translation model, chosen in the model manager, and what it is asked:
/// translate this; and, if it is a general model, can this be translated yet.
/// Whether a piece is English, or in a language spoken here, is Apple's
/// language detector's call, the same whichever model is loaded. An actor,
/// because MLX is driven from one place at a time.
///
/// Every prompt keeps its own attention cache and each call reads only what
/// changed since the last one: on an M1 reading the prompt costs as much as
/// writing the answer (`translate.py`, `judge.py`).
public actor Linguist {
    public let model: TranslationModel
    private let context: ModelContext
    /// The languages spoken here, if restricted; empty (or English alone) for any.
    private var languages: [String]
    private var system: String
    private var history: [(source: String, target: String, language: String)] = []
    private let contextPieces = 3
    private var translator: PromptCache
    private var questions: [String: PromptCache] = [:]
    private let yes: [Int32]
    private let no: [Int32]
    private let stops: Set<Int>
    private let detector = LanguageDetector()
    /// The last language named with confidence: a conversation rarely switches
    /// mid-thought, and two-word replies are where the detector is unsure.
    private var lastLanguage: String?

    public init(model: TranslationModel, at directory: URL, languages: [String]) async throws {
        // Variable shapes otherwise grow MLX's cache without bound; a phone has less to spare.
        #if os(iOS)
        MLX.GPU.set(cacheLimit: 256 << 20)
        #else
        MLX.GPU.set(cacheLimit: 1 << 30)
        #endif
        let context = try await loadModel(from: directory, using: #huggingFaceTokenizerLoader())
        yes = Self.firstTokens(context.tokenizer, ["yes", "Yes", " yes", " Yes"])
        no = Self.firstTokens(context.tokenizer, ["no", "No", " no", " No"])
        // The end-of-turn marker isn't the declared end token for every model.
        stops = Set(([context.tokenizer.eosTokenId] + ["<end_of_turn>", "<turn|>", "<|im_end|>", "<|endoftext|>"]
                .map { context.tokenizer.convertTokenToId($0) }).compactMap { $0 })
            .union(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
        translator = try PromptCache(context.model)
        self.model = model
        self.context = context
        self.languages = languages
        system = Self.system(for: languages)
    }

    public func setLanguages(_ languages: [String]) {
        if self.languages != languages { forget() }
        self.languages = languages
        system = Self.system(for: languages)
    }

    private static func system(for languages: [String]) -> String {
        let spoken = languages.filter { $0 != "en" }
        return Prompts.translate + (spoken.isEmpty ? "" : Prompts.speakers(Languages.list(spoken)))
    }

    /// The first token of each spelling; the model's answer starts with one of them.
    private static func firstTokens(_ tokenizer: any MLXLMCommon.Tokenizer, _ words: [String]) -> [Int32] {
        Array(Set(words.compactMap { tokenizer.encode(text: $0, addSpecialTokens: false).first })).map(Int32.init)
    }

    // MARK: translation

    /// English for `text`; `brief` asks a general model for the gist only, to
    /// catch up a backlog (TranslateGemma takes no instructions).
    public func translate(_ text: String, brief: Bool = false) throws -> String {
        if let concern = TranslationQuality.concern(source: text) { throw UnclearTranslation(concern) }
        let text = Clock.normalise(text)
        let language = source(of: text)
        if history.count >= 2 * contextPieces { history.removeFirst(history.count - contextPieces) }
        let prompt = try context.tokenizer.applyChatTemplate(
            messages: messages(text, language, brief), tools: nil,
            additionalContext: ["enable_thinking": false])  // Gemma 4 otherwise reasons aloud: seconds a line

        try Task.checkCancellation()
        let fresh = try translator.prepare(for: prompt)
        // English seldom needs three times the tokens of its source; a cap keeps
        // an aside from being spoken and the listener from falling behind.
        let cap = max(24, 3 * context.tokenizer.encode(text: text, addSpecialTokens: false).count)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(fresh)), model: context.model,
                                         cache: translator.kv, parameters: GenerateParameters(maxTokens: cap, temperature: 0))
        var produced: [Int] = []
        do {
            while let token = iterator.next() {
                try Task.checkCancellation()
                if stops.contains(token) { break }
                produced.append(token)
            }
        } catch {
            try translator.reset()
            throw error
        }
        // The cache may run a token past what was kept; hold it to what we know.
        translator.settle(prompt + produced)

        let out = Self.spoken(context.tokenizer.decode(tokenIds: produced, skipSpecialTokens: true))
        if let concern = TranslationQuality.concern(source: text, translation: out) {
            throw UnclearTranslation(concern)
        }
        history.append((text, out, language))
        return out
    }

    /// What is worth saying of an output: its first line, without quotes or a
    /// note in brackets at the end ("(This is a somewhat unusual phrase – the
    /// translation reflects…)", which TranslateGemma adds now and then).
    static func spoken(_ output: String) -> String {
        var out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        out = String(out.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        if let open = out.lastIndex(of: "("), out.hasSuffix(")"),
           out[open...].split(separator: " ").count > 4, open > out.startIndex {
            out = String(out[..<open])
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")).trimmingCharacters(in: .whitespaces)
    }

    private func messages(_ text: String, _ language: String, _ brief: Bool) -> [[String: any Sendable]] {
        switch model.style {
        case .translateGemma:
            // Its template: each turn names the source language; earlier pieces
            // are earlier turns. English kept as context can't be "translated"
            // from English to English, so only translated pieces go in.
            func turn(_ text: String, _ language: String) -> [String: any Sendable] {
                ["role": "user", "content": [["type": "text", "source_lang_code": language,
                                               "target_lang_code": "en", "text": text] as [String: any Sendable]]]
            }
            var messages: [[String: any Sendable]] = []
            for piece in history where piece.language != "en" {
                messages += [turn(piece.source, piece.language), ["role": "assistant", "content": piece.target]]
            }
            return messages + [turn(text, language)]
        case .instructions:
            var messages: [[String: any Sendable]] = [["role": "system", "content": system]]
            for piece in history {
                messages.append(["role": "user", "content": Prompts.piece(piece.source, brief: false)])
                messages.append(["role": "assistant", "content": piece.target])
            }
            // Not told the source language: told it, Qwen once gave German back untranslated.
            messages.append(["role": "user", "content": Prompts.piece(text, brief: brief)])
            return messages
        }
    }

    /// The language to translate from: the detector's answer when it is sure,
    /// else the last one it was sure of, else its best guess.
    private func source(of text: String) -> String {
        let guess = detector.guess(text)
        if let guess, guess.confidence >= 0.8, guess.code != "en" {
            lastLanguage = guess.code
            return guess.code
        }
        return lastLanguage ?? guess.map { $0.code == "en" ? "pl" : $0.code } ?? "pl"
    }

    /// Keep a piece that needed no translation as context for the ones that do.
    public func remember(_ text: String) {
        history.append((text, text, "en"))
        if history.count > 2 * contextPieces { history.removeFirst(history.count - contextPieces) }
    }

    public func forget() {
        history.removeAll()
        lastLanguage = nil
    }

    /// Read every prompt's instructions once, so the first real piece doesn't pay for it.
    public func warmUp() throws {
        _ = try translate("Hallo, wie geht's?")
        if model.judges { _ = try complete("Hallo") }
        forget()
    }

    // MARK: questions

    /// Can this be translated correctly now? Only a general model is asked;
    /// without one, pieces are cut on pauses and punctuation alone.
    public func complete(_ text: String) throws -> Bool {
        try Task.checkCancellation()
        guard model.judges else { return true }
        var text = text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ".?!…".contains(last) { text.removeLast() }
        return try ask(Prompts.complete, text) >= 0.5
    }

    /// Before translating: does this piece need it? English the listener
    /// understands; a language not spoken here (if restricted) is misheard.
    /// The text's own signs come first, then Apple's language detector.
    public func gate(_ text: String) -> Silence? {
        let guess = detector.guess(text)
        let foreign = text.filter { $0.isLetter && !$0.isASCII }.count
        if foreign < 2, let guess, guess.code == "en", guess.confidence >= 0.6 { return .english }
        guard languages.contains(where: { $0 != "en" }) else { return nil }
        if let verdict = Languages.evidence(text, languages) { return verdict ? nil : .language }
        // Dropping real speech is the worse mistake: only a sure guess turns it away.
        if let guess, guess.confidence >= 0.8, !languages.contains(guess.code) { return .language }
        return nil
    }

    /// How sure the model is that the answer is yes, between yes and no: one
    /// forward pass, the last position only.
    private func ask(_ instructions: String, _ text: String) throws -> Double {
        let messages = [["role": "system", "content": instructions], ["role": "user", "content": "\"\(text)\""]]
        let prompt = try context.tokenizer.applyChatTemplate(messages: messages, tools: nil,
                                                             additionalContext: ["enable_thinking": false])
        var cache = try questions[instructions] ?? PromptCache(context.model)
        let fresh = try cache.prepare(for: prompt)
        let logits = context.model(LMInput.Text(tokens: MLXArray(fresh))[text: .newAxis], cache: cache.kv, state: nil)
            .logits[0, -1]
        cache.settle(prompt)
        questions[instructions] = cache
        let margin = logits[MLXArray(yes)].max() - logits[MLXArray(no)].max()
        return Double(sigmoid(margin).item(Float.self))
    }
}

struct UnclearTranslation: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// An attention cache and the tokens it holds, reused across calls that share a prefix.
struct PromptCache {
    private(set) var kv: [KVCache]
    private let freshCache: () throws -> [KVCache]
    private(set) var tokens: [Int] = []

    init(_ model: any LanguageModel) throws {
        try self.init { try model.newCache(parameters: nil) }
    }

    init(makeCache: @escaping () throws -> [KVCache]) throws {
        freshCache = makeCache
        kv = try makeCache()
    }

    mutating func reset() throws {
        kv = try freshCache()
        tokens = []
    }

    /// Trim back to what `prompt` shares with what is held; returns the part to read.
    mutating func prepare(for prompt: [Int]) throws -> [Int] {
        guard !prompt.isEmpty else { throw Problem("The model produced an empty prompt.") }
        var keep = zip(tokens, prompt).prefix { $0 == $1 }.count
        let offset = kv.first?.offset ?? 0
        keep = min(keep, prompt.count - 1, offset)  // always read at least one token
        let trim = offset - keep
        if trim > 0 && (!canTrimPromptCache(kv) || trimPromptCache(kv, numTokens: trim) != trim) {
            // Sliding attention can no longer rewind once its ring wraps. A
            // failed trim must rebuild, not feed a suffix behind stale tokens.
            try reset()
            keep = 0
        }
        return Array(prompt[keep...])
    }

    /// After a call: the cache holds `held`, and nothing past it.
    mutating func settle(_ held: [Int]) {
        let extra = (kv.first?.offset ?? 0) - held.count
        if extra > 0 { _ = trimPromptCache(kv, numTokens: extra) }
        tokens = Array(held.prefix(kv.first?.offset ?? 0))
    }
}
