import Foundation
import InterpreterCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import PromptCache
import Tokenizers

/// Why a piece is not spoken.
public enum Silence: String, Sendable {
    case understood  // already in the listener's language: kept as context
    case language  // in no language expected here: speech recognition went astray
    case echo  // a "translation" that only repeats its source: garbled English
    case unclear  // a reproduced quality problem: shown for clarification, not spoken
}

/// The translation model, chosen in the model manager, and what it is asked:
/// translate this into the listener's language; and, if it is a general model,
/// can this be translated yet. Whether a piece is already in the listener's
/// language, or in a language spoken here, is Apple's
/// language detector's call, the same whichever model is loaded. An actor,
/// because MLX is driven from one place at a time.
///
/// Every prompt keeps its own attention cache and each call reads only what
/// changed since the last one: on an M1 reading the prompt costs as much as
/// writing the answer (`translate.py`, `judge.py`).
public actor Linguist {
    public let model: TranslationModel
    private let context: ModelContext
    /// The languages spoken here, if restricted; empty for any.
    private var languages: [String]
    /// The listener's language, which everything is interpreted into.
    private var target: String
    private var system: String
    /// Both ways round when exactly one language is spoken here besides the
    /// listener's: each piece goes into the other's language.
    private var conversation: Conversation?
    /// What was said (`source`, in `language`) and what it became (`target`, in `into`).
    private var history: [(source: String, target: String, language: String, into: String)] = []
    private let contextPieces = 3
    /// One attention cache per language translated into, so a conversation
    /// switching sides doesn't read its instructions again at every turn.
    private var translators: [String: PromptCache] = [:]
    private var questions: [String: PromptCache] = [:]
    private let yes: [Int32]
    private let no: [Int32]
    private let stops: Set<Int>
    private let detector = LanguageDetector()
    private var detectionLanguages: [String]?
    /// The last language named with confidence: a conversation rarely switches
    /// mid-thought, and two-word replies are where the detector is unsure.
    private var lastLanguage: String?

    public init(model: TranslationModel, at directory: URL, languages: [String], target: String = "en") async throws {
        // Variable shapes otherwise grow MLX's cache without bound; a phone has less to spare.
        #if os(iOS)
        MLX.Memory.cacheLimit = 256 << 20
        #else
        MLX.Memory.cacheLimit = 1 << 30
        #endif
        let context = try await loadModel(from: directory, using: #huggingFaceTokenizerLoader())
        yes = Self.firstTokens(context.tokenizer, ["yes", "Yes", " yes", " Yes"])
        no = Self.firstTokens(context.tokenizer, ["no", "No", " no", " No"])
        // The end-of-turn marker isn't the declared end token for every model.
        stops = Set(([context.tokenizer.eosTokenId] + ["<end_of_turn>", "<turn|>", "<|im_end|>", "<|endoftext|>"]
                .map { context.tokenizer.convertTokenToId($0) }).compactMap { $0 })
            .union(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
        translators[target] = try PromptCache(context.model)
        self.model = model
        self.context = context
        self.target = target
        self.languages = languages.filter { $0 != target }
        conversation = Conversation(spoken: self.languages, target: target)
        system = Self.system(for: self.languages, into: target)
    }

    /// `languages` spoken here (empty for any), interpreted into `target`.
    public func setLanguages(_ languages: [String], target: String) {
        let languages = languages.filter { $0 != target }
        if self.languages != languages || self.target != target { forget() }
        self.languages = languages
        self.target = target
        conversation = Conversation(spoken: languages, target: target)
        system = Self.system(for: languages, into: target)
        let keep = Set(conversation?.languages ?? [target])
        translators = translators.filter { keep.contains($0.key) }
    }

    /// Which way a piece goes, in a two-way conversation; nil when only the
    /// listener is listened for.
    public func direction(_ text: String) -> Direction? {
        guard let conversation else { return nil }
        let guess = detector.guess(text, languages: conversation.languages)
        let from = conversation.source(of: text, guess: guess.map { ($0.code, $0.confidence) }, last: lastLanguage)
        lastLanguage = from
        return Direction(from: from, into: conversation.other(from))
    }

    public func setRecognitionModel(_ model: RecognitionModel) {
        detectionLanguages = model == .whisper ? model.languageNames.keys.sorted() : nil
    }

    private static func system(for spoken: [String], into target: String) -> String {
        Prompts.translate(into: name(target)) + (spoken.isEmpty ? "" : Prompts.speakers(
            Languages.list(spoken, names: RecognitionModel.whisper.languageNames)))
    }

    /// The instructions for translating into `into`: one way round, the
    /// listener's as always; both ways, each side's, naming the other's
    /// language as the one spoken.
    private func instructions(into: String) -> String {
        guard let conversation else { return system }
        return Self.system(for: [conversation.other(into)], into: into)
    }

    static func name(_ code: String) -> String {
        Languages.names[code] ?? RecognitionModel.whisper.languageNames[code] ?? code
    }

    /// The first token of each spelling; the model's answer starts with one of them.
    private static func firstTokens(_ tokenizer: any MLXLMCommon.Tokenizer, _ words: [String]) -> [Int32] {
        Array(Set(words.compactMap { tokenizer.encode(text: $0, addSpecialTokens: false).first })).map(Int32.init)
    }

    // MARK: translation

    /// `text` in the listener's language, or, in a two-way conversation, the
    /// way `direction` says; `brief` asks a general model for the gist only, to
    /// catch up a backlog (TranslateGemma takes no instructions).
    public func translate(_ text: String, brief: Bool = false, direction: Direction? = nil) throws -> String {
        if let concern = TranslationQuality.concern(source: text) { throw UnclearTranslation(concern) }
        let text = Clock.normalise(text)
        let language = direction?.from ?? source(of: text)
        let into = direction?.into ?? target
        if history.count >= 2 * contextPieces { history.removeFirst(history.count - contextPieces) }
        let prompt = try context.tokenizer.applyChatTemplate(
            messages: messages(text, language, into, brief), tools: nil,
            additionalContext: ["enable_thinking": false])  // Gemma 4 otherwise reasons aloud: seconds a line

        try Task.checkCancellation()
        var translator = try translators[into] ?? PromptCache(context.model)
        defer { translators[into] = translator }
        let fresh = try translator.prepare(for: prompt)
        // English seldom needs three times the tokens of its source; a cap keeps
        // an aside from being spoken and the listener from falling behind.
        // Other languages cost a tokenizer more per word than English does.
        let factor = into == "en" ? 3 : 4
        let cap = max(24, factor * context.tokenizer.encode(text: text, addSpecialTokens: false).count)
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
        // Both ways round, a piece that came back unchanged was the other side
        // speaking and is asked again the other way: kept, it would teach the
        // model the wrong pair. One that didn't says who has the floor.
        if let direction, echoes(text, out) { return out }
        history.append((text, out, language, into))
        if let direction { lastLanguage = direction.from }
        return out
    }

    /// What is worth saying of an output: its first line, without quotes or a
    /// note in brackets at the end ("(This is a somewhat unusual phrase – the
    /// translation reflects…)", which TranslateGemma adds now and then).
    /// A first line that only announces the rest ("Okay, here's the English
    /// translation:") is skipped, and where both gendered forms are offered
    /// ("chciałem/chciałam") the first is said: the voice would read the slash.
    static func spoken(_ output: String) -> String {
        var out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count > 1, lines[0].hasSuffix(":") { lines.removeFirst() }
        out = lines.first ?? ""
        // Markdown emphasis ("not *too* good"): the voice would read the marks.
        out = out.replacing(/\*{1,2}([^*\n]+)\*{1,2}/) { String($0.1) }
        out = out.replacing(/(^|[^\p{L}\p{N}])_([^_\n]+)_(?![\p{L}\p{N}])/) { String($0.1) + String($0.2) }
        // Alternatives offered for an ambiguous fragment: the first is said.
        // "I'm asking… / I'm telling…" and "He/She places…" (the pronouns
        // spelled in full, so "and/or" and a Polish "psa/kota" stay).
        if let spaced = out.range(of: " / ") { out = String(out[..<spaced.lowerBound]) }
        out = out.replacing(/\b(he|she|him|her|his|hers|they)\/(he|she|him|her|his|hers|they)\b/.ignoresCase()) { String($0.1) }
        out = out.replacing(/(\p{L}{3,})\/(\p{L}+)/) { match in
            let (first, second) = (String(match.1), String(match.2))
            return first.prefix(3) == second.prefix(3) ? first : "\(first)/\(second)"
        }
        // A note at the end, even before a full stop: "…and (the sentence is incomplete in Italian)."
        if let open = out.lastIndex(of: "("), open > out.startIndex,
           let close = out.lastIndex(of: ")"), close > open,
           out[out.index(after: close)...].allSatisfy({ ".!?…".contains($0) || $0.isWhitespace }),
           out[open...close].split(separator: " ").count > 4 {
            out = String(out[..<open])
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")).trimmingCharacters(in: .whitespaces)
    }

    private func messages(_ text: String, _ language: String, _ target: String,
                          _ brief: Bool) -> [[String: any Sendable]] {
        switch model.style {
        case .translateGemma:
            // Its template: each turn names the source language; earlier pieces
            // are earlier turns. A piece kept as context because it was already
            // in the listener's language can't be "translated" into itself, so
            // only translated pieces go in. Both ways round, each turn names
            // its own pair, so the other side's pieces are context too.
            func turn(_ text: String, _ language: String, _ into: String) -> [String: any Sendable] {
                ["role": "user", "content": [["type": "text", "source_lang_code": language,
                                               "target_lang_code": into, "text": text] as [String: any Sendable]]]
            }
            var messages: [[String: any Sendable]] = []
            for piece in history where piece.language != piece.into {
                messages += [turn(piece.source, piece.language, piece.into), ["role": "assistant", "content": piece.target]]
            }
            return messages + [turn(text, language, target)]
        case .euroLLM:
            // Its training format, one piece at a time: earlier pieces as
            // context made a model this small echo them.
            let (from, into) = (Self.name(language), Self.name(target))
            return [["role": "user",
                     "content": "Translate the following \(from) source text to \(into):\n\(from): \(text)\n\(into): "]]
        case .instructions:
            // The instructions name one language to work into, so only pieces
            // that went the same way are earlier turns.
            var messages: [[String: any Sendable]] = [["role": "system", "content": instructions(into: target)]]
            for piece in history where piece.into == target {
                messages.append(["role": "user", "content": Prompts.piece(piece.source, brief: false, into: Self.name(target))])
                messages.append(["role": "assistant", "content": piece.target])
            }
            // Not told the source language: told it, Qwen once gave German back untranslated.
            messages.append(["role": "user", "content": Prompts.piece(text, brief: brief, into: Self.name(target))])
            return messages
        }
    }

    /// The language to translate from: the detector's answer when it is sure,
    /// else the last one it was sure of, else its best guess. Never the
    /// listener's own language: into English, Polish is the likeliest source,
    /// into anything else English is.
    private func source(of text: String) -> String {
        let guess = detector.guess(text, languages: detectionLanguages)
        if let guess, guess.confidence >= 0.8, guess.code != target {
            lastLanguage = guess.code
            return guess.code
        }
        let fallback = target == "en" ? "pl" : "en"
        return lastLanguage ?? guess.map { $0.code == target ? fallback : $0.code } ?? fallback
    }

    /// Keep a piece that needed no translation as context for the ones that do.
    public func remember(_ text: String) {
        history.append((text, text, target, target))
        if history.count > 2 * contextPieces { history.removeFirst(history.count - contextPieces) }
    }

    public func forget() {
        history.removeAll()
        lastLanguage = nil
    }

    /// Read every prompt's instructions once, so the first real piece doesn't pay for it.
    public func warmUp() throws {
        _ = try translate(target == "de" ? "Dzień dobry, jak się masz?" : "Hallo, wie geht's?")
        if let guest = conversation?.guest {  // and the other way round
            let from = guest == "de" ? "pl" : "de"
            _ = try translate(guest == "de" ? "Dzień dobry, jak się masz?" : "Hallo, wie geht's?",
                              direction: Direction(from: from, into: guest))
        }
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

    /// Before translating: does this piece need it? The listener's own
    /// language they understand; a language not spoken here (if restricted)
    /// is misheard. The text's own signs come first, then Apple's language
    /// detector.
    /// Both ways round, the listener's language is interpreted too: only a
    /// language neither side speaks is turned away.
    public func gate(_ text: String) -> Silence? {
        let guess = detector.guess(text, languages: detectionLanguages)
        if conversation == nil, let guess, guess.code == target, guess.confidence >= 0.6 {
            // English has no letters outside ASCII: two of them and the
            // detector's "English" is a misreading.
            let foreign = text.filter { $0.isLetter && !$0.isASCII }.count
            if target != "en" || foreign < 2 { return .understood }
        }
        guard !languages.isEmpty else { return nil }
        let expected = [target] + languages
        if let verdict = Languages.evidence(text, expected) { return verdict ? nil : .language }
        // Dropping real speech is the worse mistake: only a sure guess turns it away.
        if let guess, guess.confidence >= 0.8, !expected.contains(guess.code) { return .language }
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

/// Which way a piece goes in a two-way conversation: from the language it is
/// in to the other side's.
public struct Direction: Equatable, Sendable {
    public let from: String
    public let into: String
    public init(from: String, into: String) {
        self.from = from
        self.into = into
    }
    public var reversed: Direction { Direction(from: into, into: from) }
}

struct UnclearTranslation: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
