// The Swift core held to the Python one: the cases in cases/*.json, which
// tests/*.py and android/core's ParityTest read too, asked again with the
// same inputs for the same answers. A plain executable that asserts and
// exits non-zero, like voice-forge's vfcheck, so it runs with `swift run
// tccheck` and never links a model.
import Foundation
import InterpreterCore

var failures = 0
var passed = 0

@MainActor func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("✗ \(name)" + (detail().isEmpty ? "" : ": \(detail())"))
    }
}

/// One word per `step` seconds, each lasting 0.3 s.
func words(_ text: String, start: Double = 0, step: Double = 0.4) -> [Word] {
    text.split(separator: " ").enumerated().map { i, t in
        Word(String(t), start + Double(i) * step, start + Double(i) * step + 0.3)
    }
}

func segmenter(_ change: (inout SegmenterConfig) -> Void = { _ in }, judge: (@Sendable (String) async -> Bool)? = nil) -> Segmenter {
    var config = SegmenterConfig()
    config.adapt = false
    change(&config)
    return Segmenter(config: config, judge: judge)
}

/// Complete when the text ends in one of `endings`; keeps what it was asked.
final class FakeJudge: @unchecked Sendable {
    let endings: [String]
    private(set) var asked: [String] = []
    init(endings: [String]) { self.endings = endings }
    @Sendable func callAsFunction(_ text: String) async -> Bool {
        asked.append(text)
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        return endings.contains { trimmed.hasSuffix($0) }
    }
}

// MARK: the shared cases

/// cases/<name>.json, from the repository root this file sits in.
func cases(_ name: String) -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appending(path: "cases/\(name).json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        print("✗ cannot read \(url.path)")
        exit(1)
    }
    return object
}

/// One word every `step` seconds from `start`, each lasting 0.3 s, per group.
func words(_ groups: Any?) -> [Word] {
    ((groups as? [[String: Any]]) ?? []).flatMap { g -> [Word] in
        words(g["text"] as? String ?? "", start: g["start"] as? Double ?? 0, step: g["step"] as? Double ?? 0.4)
    }
}

@MainActor func configured(_ fields: [String: Any]?) -> SegmenterConfig {
    var config = SegmenterConfig()
    config.adapt = false
    for (key, value) in fields ?? [:] {
        let number = (value as? NSNumber)?.doubleValue ?? 0
        switch key {
        case "hop": config.hop = number
        case "leftContext": config.leftContext = number
        case "longPause": config.longPause = number
        case "softSegment": config.softSegment = number
        case "maxSegment": config.maxSegment = number
        case "hardSegment": config.hardSegment = number
        case "minWords": config.minWords = Int(number)
        case "maxLongPause": config.maxLongPause = number
        case "judgePause": config.judgePause = number
        case "judgeTries": config.judgeTries = Int(number)
        default: print("✗ unknown config field \(key)"); failures += 1
        }
    }
    return config
}

// MARK: segmenter

for case let c as [String: Any] in cases("segmenter")["cases"] as? [Any] ?? [] {
    let name = c["name"] as? String ?? "?"
    let judge = (c["judge"] as? [String]).map { FakeJudge(endings: $0) }
    var ask: (@Sendable (String) async -> Bool)?
    if let judge { ask = { text in await judge(text) } }
    let s = Segmenter(config: configured(c["config"] as? [String: Any]), judge: ask)
    if let mark = c["startMark"] as? Double { s.mark = mark }
    var ok = true
    var detail = ""
    for (i, item) in (c["steps"] as? [Any] ?? []).enumerated() {
        guard let step = item as? [String: Any] else { continue }
        let out = await s.step(now: step["now"] as? Double ?? 0, words: words(step["words"]),
                               silence: step["silence"] as? Double ?? 0)
        if let expect = step["expect"] as? [[String: Any]] {
            var matches = out.count == expect.count
            for (segment, want) in zip(out, expect) {
                if let text = want["text"] as? String, segment.text != text { matches = false }
                if let reason = want["reason"] as? String, segment.reason != reason { matches = false }
            }
            if !matches { ok = false; detail = "step \(i): \(out.map { "\($0.text) [\($0.reason)]" })" }
        }
        if let asked = step["asked"] as? [String], judge?.asked != asked { ok = false; detail = "step \(i): asked \(judge?.asked ?? [])" }
    }
    let after = c["after"] as? [String: Any] ?? [:]
    if let mark = after["mark"] as? Double, abs(s.mark - mark) > 1e-9 { ok = false; detail = "mark \(s.mark)" }
    if let pending = after["pending"] as? [String], s.pending.map { $0.text } != pending { ok = false; detail = "pending \(s.pending.map { $0.text })" }
    if let asked = after["asked"] as? [String], judge?.asked != asked { ok = false; detail = "asked \(judge?.asked ?? [])" }
    if let heard = c["newWords"] as? [String: Any] {
        let base = (heard["fromMark"] as? Bool ?? false) ? s.mark : 0
        let given = (heard["words"] as? [[Any]] ?? []).map {
            Word($0[0] as? String ?? "", base + (($0[1] as? NSNumber)?.doubleValue ?? 0), base + (($0[2] as? NSNumber)?.doubleValue ?? 0))
        }
        let kept = s.newWords(given).map { $0.text }
        if kept != heard["expect"] as? [String] ?? [] { ok = false; detail = "new words \(kept)" }
    }
    check(name, ok, detail)
}
do {
    // Compares thresholds, not outputs, so it stays here rather than in cases/.
    var config = SegmenterConfig()
    config.adapt = true
    let s = Segmenter(config: config)
    let base = s.longPauseThreshold()
    for i in 0..<10 { _ = await s.step(now: 0, words: words("ein sehr langsamer Satz.", start: Double(i) * 10, step: 1.2), silence: 9) }
    check("pauses stretch for a hesitant speaker",
          base < s.longPauseThreshold() && s.longPauseThreshold() <= s.config.maxLongPause)
}

// MARK: clock times

let clock = cases("clock")
for case let pair as [String] in clock["becomeDigits"] as? [Any] ?? [] {
    check("clock: \(pair[0])", Clock.normalise(pair[0]) == pair[1], Clock.normalise(pair[0]))
}
for case let text as String in clock["leftAlone"] as? [Any] ?? [] {
    check("clock leaves alone: \(text)", Clock.normalise(text) == text, Clock.normalise(text))
}

// MARK: echoes

let echo = cases("echoes")
for case let pair as [String] in echo["echoes"] as? [Any] ?? [] {
    check("echo: \(pair[1])", echoes(pair[0], pair[1]))
}
for case let pair as [String] in echo["notEchoes"] as? [Any] ?? [] {
    check("not an echo: \(pair[1])", !echoes(pair[0], pair[1]))
}

// MARK: language evidence

for case let c as [String: Any] in cases("language-evidence")["cases"] as? [Any] ?? [] {
    let text = c["text"] as? String ?? "", expected = c["expected"] as? [String] ?? []
    let got = Languages.evidence(text, expected)
    switch c["evidence"] {
    case let want as Bool: check("evidence \(want): \(text)", got == want, "\(String(describing: got))")
    case let want as String where want == "notFalse": check("evidence not false: \(text)", got != false)
    default: check("no evidence either way: \(text)", got == nil, "\(String(describing: got))")
    }
}
check("language list reads naturally", Languages.list(["pl", "hu", "nl"]) == "Polish, Hungarian and Dutch")

// MARK: catch-up

let backlog = Backlog(), catchUp = cases("catch-up")
for case let pair as [Any] in catchUp["brief"] as? [Any] ?? [] {
    let seconds = (pair[0] as? NSNumber)?.doubleValue ?? 0
    check("catch-up brief at \(seconds) s", backlog.brief(seconds) == (pair[1] as? Bool))
}
for case let pair as [Any] in catchUp["pace"] as? [Any] ?? [] {
    let seconds = (pair[0] as? NSNumber)?.doubleValue ?? 0, pace = (pair[1] as? NSNumber)?.doubleValue ?? 0
    check("catch-up pace at \(seconds) s", abs(backlog.pace(seconds) - pace) < 1e-9, "\(backlog.pace(seconds))")
}

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
