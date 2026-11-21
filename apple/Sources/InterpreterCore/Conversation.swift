/// Two people, two languages, both ways. When exactly one language is named
/// as spoken here, beside the listener's own, the listener's speech is no
/// longer only understood and kept as context: it is translated into the
/// other language and said aloud, as the other's is into theirs. Nobody stops
/// Live or swaps the pickers between turns.
///
/// Which way a piece goes is decided from its text, as the gate already
/// decides what a piece is in: the letters and words that all but give a
/// language away first, then Apple's language detector held to the two, then,
/// when neither is sure, the side that spoke last. A conversation rarely
/// switches mid-thought, and two-word replies are where the detector is unsure.
public struct Conversation: Equatable, Sendable {
    /// The one language named as spoken here.
    public let guest: String
    /// The listener's language, which the guest's speech is interpreted into.
    public let host: String

    /// Only for exactly one language spoken here besides the listener's: none
    /// means any language, several mean the listener is only listening.
    public init?(spoken: [String], target: String) {
        let spoken = spoken.filter { $0 != target }
        guard spoken.count == 1 else { return nil }
        guest = spoken[0]
        host = target
    }

    public var languages: [String] { [guest, host] }

    /// The language a piece in `code` is interpreted into.
    public func other(_ code: String) -> String { code == host ? guest : host }

    /// Below this the detector, held to two languages, is close to a coin toss.
    public static let sure = 0.65

    /// Which of the two `text` is in. `guess` is the detector's answer held to
    /// the two; `last` the side that spoke before.
    public func source(of text: String, guess: (code: String, confidence: Double)?, last: String?) -> String {
        if let evident = evident(text) { return evident }
        if let guess, languages.contains(guess.code), guess.confidence >= Self.sure { return guess.code }
        if let last, languages.contains(last) { return last }
        if let guess, languages.contains(guess.code) { return guess.code }
        return guest
    }

    /// What the text itself says: one side's letters or everyday words, or
    /// letters of another script or language that rule the other side out.
    /// Nil when it says nothing, or the same for both.
    func evident(_ text: String) -> String? {
        let forGuest = Languages.evidence(text, [guest])
        let forHost = Languages.evidence(text, [host])
        switch (forGuest, forHost) {
        case (true?, let h) where h != true: return guest
        case (let g, true?) where g != true: return host
        case (false?, nil): return host
        case (nil, false?): return guest
        default: return nil
        }
    }
}

/// What the interpreter's own voice said lately, so that a microphone hearing
/// it from the phone's speaker doesn't send it back the other way. One way
/// round this never mattered: the voice speaks the listener's language, which
/// the gate keeps quiet. Both ways round, it would bounce between the two.
///
/// A piece is the voice's own when it was heard while the voice was playing,
/// or just after, and nearly all its words are in what was said.
public struct SpokenEchoes: Sendable {
    struct Said: Sendable {
        let words: Set<String>
        let start: Double
        let end: Double
    }
    private var said: [Said] = []
    /// Seconds of slack either side: the stream clock and the playback clock
    /// differ by the input's latency, and a room rings on.
    let early: Double
    let late: Double
    let keep: Int

    public init(early: Double = 0.75, late: Double = 1.5, keep: Int = 8) {
        self.early = early
        self.late = late
        self.keep = keep
    }

    /// The voice says `text` from `start` to `end`, in stream seconds.
    public mutating func said(_ text: String, from start: Double, to end: Double) {
        let words = Set(Self.words(text))
        guard !words.isEmpty else { return }
        said.append(Said(words: words, start: start, end: end))
        if said.count > keep { said.removeFirst(said.count - keep) }
    }

    /// Whether `text`, heard from `start` to `end`, is the voice coming back.
    public func heard(_ text: String, from start: Double, to end: Double) -> Bool {
        let words = Self.words(text)
        guard !words.isEmpty else { return false }
        return said.contains { clip in
            guard end >= clip.start - early, start <= clip.end + late else { return false }
            let found = words.filter { clip.words.contains($0) }.count
            return Double(found) / Double(words.count) >= 0.6
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}
