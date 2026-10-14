import Foundation

/// espeak-ng, corrected: the phonemizer the polyglot snepssen voice was
/// trained through, so it is asked for exactly the symbols it learned.
///
/// A port of voice-polyglot's `tools/polyphon.py`, rule for rule, not shared
/// (the same rule as `EspeakPhonemizer`): a change there is regenerated into
/// `Tests/InterpreterEngineTests/Fixtures/polyphon_ids.tsv` and made here by
/// hand, and `PolyphonTests` holds the two to the same phoneme ids.
///
/// Two kinds of rule, both plain rewrites:
///   fixes        espeak-ng says the wrong sound (Polish hard dz, Hungarian
///                silent h, n before b).
///   separations  one espeak-ng symbol for sounds that differ between the
///                languages (German, Dutch, Italian and Spanish r; Dutch g).
///                The voice has no language switch, so a sound only one
///                language has gets a symbol only that language uses.
/// English goes through untouched. A language the voice was not trained on
/// goes through plain espeak-ng: no corrections exist for it.
///
/// Everything works on Unicode scalars, never `String` comparison: Swift
/// treats `c` + combining cedilla and the precomposed `ç` as equal, and the
/// voice's symbol table does not.
public enum Polyphon {
    /// The languages the voice was trained on, as the app offers them.
    public static let trained = ["en", "pl", "hu", "de", "nl", "fr", "es", "it"]

    /// espeak-ng's voice for a language; any other code is tried as is.
    static func espeakVoice(_ language: String) -> String { language == "en" ? "en-us" : language }

    // MARK: spelling, before espeak-ng

    private static let spelling: [String: [(NSRegularExpression, String)]] = [
        "hu": [
            // Word-final h is silent in these; espeak-ng says it ("méh" meːh).
            (regex(#"\b(mé|ju|cse|olá|plé)h\b"#, caseInsensitive: true), "$1"),
            // n before b is m (különben); espeak-ng already does it before p.
            (regex("nb"), "mb"),
            // sz + s is a long s-sound (egészség), which "ss" gives.
            (regex("szs"), "ss"),
        ],
    ]

    // MARK: IPA, after espeak-ng

    private static let ipa: [String: [([Unicode.Scalar], [Unicode.Scalar])]] = [
        "de": [
            (["c", "\u{327}"], ["\u{E7}"]),  // ç precomposed: c alone is Hungarian ty
            (["\u{25C}"], ["\u{250}"]),  // -er: ɜ -> ɐ
            (["\u{27E}"], ["\u{250}"]),  // r after a vowel: ɾ -> ɐ
            (["r"], ["\u{281}"]),  // r before a vowel: uvular ʁ
        ],
        "nl": [
            (["\u{263}"], ["\u{3C7}"]),  // g: ɣ -> χ
            (["x"], ["\u{3C7}"]),  // ch: x -> χ
            (["\u{27E}"], ["\u{280}"]),  // r: ɾ -> ʀ
            (["r"], ["\u{280}"]),  // r: r -> ʀ
        ],
        "it": [
            (["\u{27E}"], ["r"]),  // one trilled r, word-initial too
        ],
    ]

    private static let vowels = "aeiouyæøœɐɑɒɔəɘɛɜɞɤɨɪɯɵɶʉʊʌʏ"
    private static let marks = "ˈˌːˑ\u{32F}\u{329}\u{32A}\u{33A}\u{33B}\u{31D}\u{303}\u{30A}ʲʷˤ˞"
    /// A doubled consonant, which espeak-ng writes two ways (Italian fatto tː
    /// but nonno nn), as one: Cː.
    private static let double = regex(#"([^\s"# + vowels + marks + #"'\-,.?!;:])\1(?!ː)"#)
    private static let flags = regex(#"\([^)]+\)"#)
    private static let sentenceBreak = regex(#"(?<=[.!?])\s+"#)
    private static let word = regex(#"[\p{L}\p{Nl}\p{No}]+(?:['’-][\p{L}\p{Nl}\p{No}]+)*"#)
    private static let dz = regex("dzi|dź|dż|dz")

    // MARK: phonemes

    /// Sentences of symbols, as the voice's training data was made: one list
    /// per sentence, punctuation kept, a space after , : and ;.
    static func sentences(_ text: String, language: String, espeak: EspeakPhonemizer) throws -> [[Unicode.Scalar]] {
        var text = text
        for (pattern, template) in spelling[language] ?? [] { text = replace(pattern, in: text, with: template) }
        let raw = try plain(text, espeak: espeak)
        guard trained.contains(language), language != "en" else { return raw }
        let textSentences = split(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return raw.enumerated().map { n, sentence in
            var ipa = sentence
            if language == "pl", n < textSentences.count {
                let textWords = matches(word, in: textSentences[n])
                let ipaWords = ipa.split(separator: " ", omittingEmptySubsequences: false).map(Array.init)
                if textWords.count == ipaWords.count {
                    ipa = Array(zip(textWords, ipaWords).map { polishHardDz($0, $1) }.joined(separator: [" "]))
                } else {
                    // espeak-ng fuses clitics ("nie walcz"): the sentence as one word.
                    ipa = polishHardDz(textWords.joined(separator: " "), ipa)
                }
            }
            for (from, to) in Self.ipa[language] ?? [] { ipa = replaceAll(from, with: to, in: ipa) }
            var string = String(String.UnicodeScalarView(ipa))
            string = replace(double, in: string, with: "$1ː")
            return Self.symbols(string)
        }
    }

    /// espeak-ng's sentences, uncorrected: piper's `EspeakPhonemizer.phonemize`.
    static func plain(_ text: String, espeak: EspeakPhonemizer) throws -> [[Unicode.Scalar]] {
        var all: [[Unicode.Scalar]] = []
        var sentence: [Unicode.Scalar] = []
        for clause in try espeak.clauses(for: text) {
            var phonemes = replace(flags, in: clause.phonemes, with: "") + clause.terminator
            if [",", ":", ";"].contains(clause.terminator) { phonemes += " " }
            sentence += phonemes.decomposedStringWithCanonicalMapping.unicodeScalars
            if clause.endOfSentence {
                all.append(sentence)
                sentence = []
            }
        }
        if !sentence.isEmpty { all.append(sentence) }
        return all
    }

    /// Ids for the voice: `^`, each symbol and a pad, `$`, per sentence, chained.
    static func ids(_ sentences: [[Unicode.Scalar]], map: [String: [Int]]) -> [Int] {
        let pad = map["_"] ?? []
        return sentences.flatMap { sentence in
            var ids = (map["^"] ?? []) + pad
            for scalar in sentence {
                guard let id = map[String(scalar)] else { continue }
                ids += id + pad
            }
            return ids + (map["$"] ?? [])
        }
    }

    /// One symbol per scalar, except a precomposed ç, which the table has.
    private static func symbols(_ ipa: String) -> [Unicode.Scalar] {
        replaceAll(["c", "\u{327}"], with: ["\u{E7}"], in: Array(ipa.decomposedStringWithCanonicalMapping.unicodeScalars))
    }

    /// espeak-ng reads every Polish dz as soft dʑ (dzwon, bardzo). Each dʑ in
    /// a word's IPA comes, in order, from one of dzi / dź / hard dz in its
    /// spelling; the hard ones become dz. If the counts disagree, as with a dʑ
    /// from voicing across words, the word is left alone.
    static func polishHardDz(_ word: String, _ ipa: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let kinds = matches(dz, in: word.lowercased()).filter { $0 != "dż" }.map { $0 == "dz" }
        let soft: [Unicode.Scalar] = ["d", "\u{291}"]
        let hits = ipa.indices.filter { $0 + 1 < ipa.count && Array(ipa[$0...$0 + 1]) == soft }
        guard kinds.contains(true), hits.count == kinds.count else { return ipa }
        var out = ipa
        for (hard, at) in zip(kinds, hits) where hard { out[at + 1] = "z" }
        return out
    }

    // MARK: helpers

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Python's `re.split(r"(?<=[.!?])\s+", text)`, empty pieces dropped.
    private static func split(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var start = 0
        for match in sentenceBreak.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: start))
        return pieces.filter { !$0.isEmpty }
    }

    /// `str.replace` on scalars: left to right, non-overlapping.
    private static func replaceAll(_ from: [Unicode.Scalar], with to: [Unicode.Scalar],
                                   in scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < scalars.count {
            if i + from.count <= scalars.count, Array(scalars[i..<i + from.count]) == from {
                out += to
                i += from.count
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return out
    }
}
