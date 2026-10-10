/// Decides when enough of the speech has arrived to hand a piece on.
///
/// A port of `segmenter.py`, held to it by `tccheck`; the Python file carries
/// the reasoning behind each rule and the measurements that set the numbers.
///
/// The ASR re-reads the uncommitted tail every hop, so each `step` sees a fresh
/// hypothesis for everything after the commit mark. Words are committed once
/// two passes agree on them (aligned word by word, 80% of a prefix), and only
/// at a safe place:
///
///   sentence  a sentence-final mark with agreed speech after it. Parakeet ends
///             every window with a full stop, and a mid-clause hesitation earns
///             one ("dass wir."); speech past it is the only proof it is real.
///   judged    a short pause after stable speech, and the judge says it can be
///             translated on its own.
///   pause     silence long enough, by the VAD or since the last word heard.
///   clause    past `softSegment` with no sentence end: the latest comma the
///             judge accepts.
///   force     past `maxSegment`: wherever the judge accepts; past
///             `hardSegment`: the widest gap regardless.
public struct SegmenterConfig: Sendable {
    public var hop = 0.5  // seconds of audio between ASR passes
    public var leftContext = 0.5  // committed audio re-fed ahead of the mark
    public var longPause = 1.4  // silence that commits everything said so far
    public var softSegment = 4.0  // uncommitted speech past which a comma will do
    public var maxSegment = 5.0  // uncommitted speech that forces a cut the judge accepts
    public var hardSegment = 6.0  // uncommitted speech that forces a cut, accepted or not
    public var minWords = 3  // shorter sentences wait to join the next one
    public var adapt = true  // stretch the long pause to the speaker's hesitations
    public var maxLongPause = 3.0  // ceiling on the adapted long pause
    public var judgePause = 0.4  // silence after which the judge is asked
    public var judgeTries = 3  // candidate cut points put to the judge per decision

    public init() {}
}

let sentenceEnd: [Character] = [".", "?", "!"]
let clauseEnd: [Character] = [",", ";", ":", "—", "–"]
let timingSlop = 0.12  // ASR word times wander about this much between passes
let stableShare = 0.8  // of a prefix's words that must agree with the last pass

public func endsSentence(_ text: String) -> Bool {
    guard let last = text.last, sentenceEnd.contains(last) else { return false }
    return !text.hasSuffix("...") && !text.hasSuffix("…")
}

/// What must agree between passes: the word, and whether it ends a sentence.
/// Case and commas may flicker; a sentence end moving is a real change.
struct Key: Hashable {
    let word: String
    let ends: Bool

    init(_ w: Word) {
        word = String(w.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" })
        ends = endsSentence(w.text)
    }
}

public final class Segmenter {
    public let config: SegmenterConfig
    /// "Can this be translated on its own yet?"
    public var judge: ((String) -> Bool)?
    public var mark = 0.0  // stream time up to which everything is committed
    public private(set) var pending: [Word] = []  // the latest hypothesis for what is not committed
    private var last: Word?  // the last committed word
    private var gaps: [Double] = []
    private var verdicts: [String: Bool] = [:]
    private var count = 0

    public init(config: SegmenterConfig = SegmenterConfig(), judge: ((String) -> Bool)? = nil) {
        self.config = config
        self.judge = judge
    }

    public func longPauseThreshold() -> Double {
        guard config.adapt, gaps.count >= 8 else { return config.longPause }
        return min(max(config.longPause, percentile(gaps, 98) * 1.6), config.maxLongPause)
    }

    /// Where the next ASR window should begin, in stream seconds.
    public func windowStart() -> Double { max(0, mark - config.leftContext) }

    /// Drop the re-recognised left context, keeping words past the mark.
    public func newWords(_ words: [Word]) -> [Word] {
        var kept = words.filter { ($0.start + $0.end) / 2 >= mark - timingSlop }
        if let first = kept.first, let last,
           first.start < mark - timingSlop || (first.start < mark && Key(first).word == Key(last).word) {
            kept.removeFirst()  // the committed word again, re-heard or re-timed
        }
        return kept
    }

    /// Advance with the latest hypothesis for the uncommitted tail. `words` must
    /// already be filtered by `newWords`; `silence` is how long the VAD has heard
    /// no speech, as of `now`.
    public func step(now: Double, words: [Word], silence: Double) -> [Segment] {
        var words = words
        var agreed = Self.agreed(pending, words)
        var segments: [Segment] = []
        while !words.isEmpty {
            // The VAD can go on hearing "speech" (noise, a faint voice) long after
            // the last word anyone could transcribe; that is a pause too.
            let heardGap = now - words[words.count - 1].end
            let (cut, reason) = decide(words, agreed, silence, heardGap)
            if cut == 0 { break }
            segments.append(commit(Array(words[..<cut]), reason, now))
            words = Array(words[cut...])
            agreed = Array(agreed[cut...])
        }
        pending = words
        return segments
    }

    /// End of stream: commit whatever is left.
    public func flush(now: Double, words: [Word]) -> [Segment] {
        pending = []
        return words.isEmpty ? [] : [commit(words, "flush", now)]
    }

    /// Slide the mark through silence so ASR windows stay short.
    public func advanceIdle(now: Double) {
        if pending.isEmpty { mark = max(mark, now - config.leftContext) }
    }

    private func decide(_ words: [Word], _ agreed: [Bool], _ silence: Double,
                        _ heardGap: Double) -> (Int, String) {
        let c = config
        if max(silence, heardGap) >= longPauseThreshold() { return (words.count, "pause") }

        // Latest sentence end with stable speech after it: the mark and the word
        // beyond it both heard the same on both passes.
        let stable = Self.stable(agreed)
        if stable >= 2 {
            for i in stride(from: stable - 2, through: 0, by: -1)
            where endsSentence(words[i].text) && agreed[i] && agreed[i + 1] && i + 1 >= c.minWords {
                return (i + 1, "sentence")
            }
        }

        if judge != nil, silence >= c.judgePause, stable == words.count, words.count >= c.minWords,
           complete(words) {
            return (words.count, "judged")
        }

        let span = words[words.count - 1].end - words[0].start
        if span >= c.softSegment {
            let cut = firstComplete(words, Self.clauseCuts(words, stable))
            if cut > 0 { return (cut, "clause") }
        }
        if span >= c.maxSegment && stable >= 2 {
            let cuts = Self.clauseCuts(words, stable) + Self.gapCuts(words, stable)
            guard judge != nil else { return (cuts.first ?? stable - 1, "force") }
            // No cut it accepts: better late than wrong, up to the cap below.
            let cut = firstComplete(words, [stable] + cuts)
            if cut > 0 { return (cut, "force") }
        }
        if span >= c.hardSegment {  // never settles, or nothing acceptable: cut what we have
            let cuts = Self.clauseCuts(words, words.count) + Self.gapCuts(words, words.count)
            return (cuts.first ?? words.count, "force")
        }
        return (0, "")
    }

    /// The first cut whose words stand alone; without a judge, simply the first.
    private func firstComplete(_ words: [Word], _ cuts: [Int]) -> Int {
        guard judge != nil else { return cuts.first ?? 0 }
        return cuts.prefix(config.judgeTries).first { complete(Array(words[..<$0])) } ?? 0
    }

    private func complete(_ words: [Word]) -> Bool {
        let text = words.map(\.text).joined(separator: " ")
        if let verdict = verdicts[text] { return verdict }
        if verdicts.count > 256 { verdicts.removeAll() }
        let verdict = judge?(text) ?? true
        verdicts[text] = verdict
        return verdict
    }

    private func commit(_ words: [Word], _ reason: String, _ now: Double) -> Segment {
        for (a, b) in zip(words, words.dropFirst()) where !endsSentence(a.text) {
            gaps.append(max(0, b.start - a.end))
        }
        if gaps.count > 200 { gaps.removeFirst(gaps.count - 200) }
        mark = words[words.count - 1].end
        last = words[words.count - 1]
        defer { count += 1 }
        return Segment(index: count, words: words, reason: reason, decidedAt: now)
    }

    /// Which of `words` the previous pass also heard, aligned word by word.
    static func agreed(_ previous: [Word], _ words: [Word]) -> [Bool] {
        var agreed = [Bool](repeating: false, count: words.count)
        for block in SequenceMatcher(previous.map(Key.init), words.map(Key.init)).matchingBlocks() {
            for j in block.j..<(block.j + block.n) { agreed[j] = true }
        }
        return agreed
    }

    /// Longest prefix ending on an agreed word with `stableShare` of its words agreed.
    static func stable(_ agreed: [Bool]) -> Int {
        var (best, count) = (0, 0)
        for (n, ok) in zip(1..., agreed) {
            if ok { count += 1 }
            if ok && Double(count) >= stableShare * Double(n) { best = n }
        }
        return best
    }

    /// Cuts after clause marks in the first `stable` words, latest first.
    static func clauseCuts(_ words: [Word], _ stable: Int) -> [Int] {
        guard stable >= 2 else { return [] }
        return stride(from: stable - 2, through: 0, by: -1)
            .filter { i in words[i].text.last.map(clauseEnd.contains) == true && longEnough(words, i) }
            .map { $0 + 1 }
    }

    /// Cuts at the gaps between the first `stable` words, widest first.
    static func gapCuts(_ words: [Word], _ stable: Int) -> [Int] {
        guard stable >= 2 else { return [] }
        return (0..<(stable - 1)).filter { longEnough(words, $0) }
            .map { (gap: words[$0 + 1].start - words[$0].end, i: $0) }
            .sorted { ($0.gap, $0.i) > ($1.gap, $1.i) }  // as Python's sorted(reverse=True)
            .map { $0.i + 1 }
    }

    /// A cut after word i keeps at least 40% of the pending speech (or 3 s) in front.
    static func longEnough(_ words: [Word], _ i: Int) -> Bool {
        let span = words[words.count - 1].end - words[0].start
        return words[i].end - words[0].start >= min(0.4 * span, 3.0)
    }
}

/// numpy.percentile with its default linear interpolation.
func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    let rank = p / 100 * Double(sorted.count - 1)
    let (lo, hi) = (Int(rank.rounded(.down)), Int(rank.rounded(.up)))
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
}
