/// One recognised word, timed in seconds from the start of the stream.
public struct Word: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(_ text: String, _ start: Double, _ end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A run of words the segmenter has committed: passed on, never revised.
public struct Segment: Equatable, Sendable {
    public let index: Int
    public let words: [Word]
    /// "sentence", "judged", "pause", "clause", "force" or "flush"; joined with "+" when merged.
    public let reason: String
    /// Stream time at which the commit decision existed.
    public var decidedAt: Double
    /// If merged: where each piece in it ended, so lag can be counted for every one.
    public var parts: [Double] = []

    public init(index: Int, words: [Word], reason: String, decidedAt: Double, parts: [Double] = []) {
        self.index = index
        self.words = words
        self.reason = reason
        self.decidedAt = decidedAt
        self.parts = parts
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
    public var start: Double { words.first?.start ?? 0 }
    public var end: Double { words.last?.end ?? 0 }

    /// Several waiting pieces as one, timed from the first word to the last.
    public static func combine(_ segments: [Segment]) -> Segment {
        guard segments.count > 1, let first = segments.first, let last = segments.last else { return segments[0] }
        var reasons: [String] = []
        for s in segments where !reasons.contains(s.reason) { reasons.append(s.reason) }
        return Segment(index: first.index, words: segments.flatMap(\.words), reason: reasons.joined(separator: "+"),
                       decidedAt: last.decidedAt, parts: segments.map(\.end))
    }
}
