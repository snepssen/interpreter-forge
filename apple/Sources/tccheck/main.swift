// The Swift core held to the Python one: every check here is a test in
// tests/*.py asked again, with the same inputs and the same answers. A plain
// executable that asserts and exits non-zero, like voice-forge's vfcheck, so
// it runs with `swift run tccheck` and never links a model.
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
    init(_ endings: String...) { self.endings = endings }
    @Sendable func callAsFunction(_ text: String) async -> Bool {
        asked.append(text)
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        return endings.contains { trimmed.hasSuffix($0) }
    }
}

// MARK: segmenter

do {
    let s = segmenter()
    let hyp = words("Ich wollte nur sagen.")
    let first = await s.step(now: 2, words: hyp, silence: 0)
    let second = await s.step(now: 2.5, words: hyp, silence: 0)
    check("full stop at window end is not trusted", first.isEmpty && second.isEmpty)
}
do {
    let s = segmenter()
    let hyp = words("Ich wollte nur sagen. Dass wir")
    let first = await s.step(now: 2.5, words: hyp, silence: 0)
    let second = await s.step(now: 3, words: hyp, silence: 0)
    check("sentence end with stable speech after it commits",
          first.isEmpty && second.map(\.text) == ["Ich wollte nur sagen."] && second.first?.reason == "sentence"
              && s.mark == hyp[3].end && s.pending.map(\.text) == ["Dass", "wir"], "\(second)")
}
do {
    let s = segmenter()
    _ = await s.step(now: 2.5, words: words("Ich wollte nur sagen. Dass wir"), silence: 0)
    let out = await s.step(now: 3, words: words("Ich wollte nur sagen, dass wir morgen"), silence: 0)
    check("full stop that moves is not stable", out.isEmpty)
}
do {
    let s = segmenter()
    let hyp = words("Ich wollte sagen, dass wir.")
    _ = await s.step(now: 2, words: hyp, silence: 0)
    let out = await s.step(now: 3, words: hyp, silence: 1.1)
    check("hesitation after a final full stop does not confirm it", out.isEmpty)
}
do {
    let s = segmenter()
    _ = await s.step(now: 2.5, words: words("ich wollte nur sagen. Dass wir"), silence: 0)
    let out = await s.step(now: 3, words: words("Ich wollte nur, sagen. dass wir"), silence: 0)
    check("case and comma flicker still counts as stable", out.map(\.text) == ["Ich wollte nur, sagen."], "\(out)")
}
do {
    let s = segmenter()
    let hyp = words("Also ich wollte eigentlich")
    _ = await s.step(now: 2, words: hyp, silence: 0.5)
    let out = await s.step(now: 2.5, words: hyp, silence: 1)
    check("mid-sentence hesitation waits", out.isEmpty)
}
do {
    let s = segmenter()
    let out = await s.step(now: 4, words: words("Also ich wollte eigentlich"), silence: 1.5)
    check("long pause commits everything",
          out.map(\.text) == ["Also ich wollte eigentlich"] && out.first?.reason == "pause" && s.pending.isEmpty)
}
do {
    let s = segmenter()
    let short = words("Ja. Das ist")
    _ = await s.step(now: 1.5, words: short, silence: 0)
    let waited = await s.step(now: 2, words: short, silence: 0).isEmpty
    let hyp = words("Ja. Das ist gut. Und dann")
    _ = await s.step(now: 2.5, words: hyp, silence: 0)
    let out = await s.step(now: 3, words: hyp, silence: 0)
    check("short sentence waits to join the next", waited && out.map(\.text) == ["Ja. Das ist gut."], "\(out)")
}
do {
    let s = segmenter()
    let hyp = words("Das ist ein Satz. Und noch einer.")
    _ = await s.step(now: 3, words: hyp, silence: 0)
    let out = await s.step(now: 3.5, words: hyp, silence: 0)
    check("earlier sentence end commits when the latest is unconfirmed", out.map(\.text) == ["Das ist ein Satz."])
}
do {
    let s = segmenter { $0.softSegment = 4 }
    let hyp = words("wir haben das gemacht, weil es nötig war, und dann haben wir noch")
    _ = await s.step(now: 5, words: hyp, silence: 0)
    let out = await s.step(now: 5.5, words: hyp, silence: 0)
    check("run-on speech is cut at the last comma",
          out.map(\.text) == ["wir haben das gemacht, weil es nötig war,"] && out.first?.reason == "clause", "\(out)")
}
do {
    let s = segmenter { $0.softSegment = 4; $0.maxSegment = 10; $0.hardSegment = 15 }
    let hyp = words("Ja, also wir haben das gemacht weil es nötig war und dann haben wir noch")
    _ = await s.step(now: 5, words: hyp, silence: 0)
    let out = await s.step(now: 5.5, words: hyp, silence: 0)
    check("comma too early to leave a real piece is skipped", out.isEmpty)
}
do {
    let s = segmenter { $0.softSegment = 3; $0.maxSegment = 4 }
    let hyp = words("eins zwei drei vier fünf sechs sieben") + words("acht neun zehn elf zwölf", start: 3.6)
    _ = await s.step(now: 6, words: hyp, silence: 0)
    let out = await s.step(now: 6.5, words: hyp, silence: 0)
    check("run-on speech without commas is cut at the widest gap",
          out.map(\.text) == ["eins zwei drei vier fünf sechs sieben"] && out.first?.reason == "force", "\(out)")
}
do {
    let s = segmenter()
    s.mark = 1
    check("left-context words are dropped",
          s.newWords([Word("alt.", 0.6, 0.95), Word("neu", 1.1, 1.4)]).map(\.text) == ["neu"])
}
do {
    let s = segmenter()
    let hyp = words("Das ist ein Satz. Der nächste")
    _ = await s.step(now: 2.5, words: hyp, silence: 0)
    _ = await s.step(now: 3, words: hyp, silence: 0)
    let drifted = [Word("Satz.", 1.25, 1.45), Word("Der", 1.42, 1.6), Word("nächste", 1.7, 2.0)]
    check("next word survives timing drift, committed word does not repeat",
          s.newWords(drifted).map(\.text) == ["Der", "nächste"])
}
do {
    let s = Segmenter(config: SegmenterConfig())
    let base = s.longPauseThreshold()
    for i in 0..<10 { _ = await s.step(now: 0, words: words("ein sehr langsamer Satz.", start: Double(i) * 10, step: 1.2), silence: 9) }
    check("pauses stretch for a hesitant speaker",
          base < s.longPauseThreshold() && s.longPauseThreshold() <= s.config.maxLongPause)
}
do {
    let s = segmenter()
    _ = await s.step(now: 3, words: words("Meldet sich bitte bei mir"), silence: 2)
    let reheard = [Word("Mehr.", s.mark - 0.25, s.mark + 0.05), Word("Danke.", s.mark + 1.5, s.mark + 1.9)]
    check("committed word re-heard differently is not repeated", s.newWords(reheard).map(\.text) == ["Danke."])
}
do {
    let judge = FakeJudge("anfangen")
    let s = segmenter(judge: judge.callAsFunction)
    let hyp = words("dass wir um zehn anfangen.")
    let first = await s.step(now: 2.5, words: hyp, silence: 0)
    let out = await s.step(now: 3, words: hyp, silence: 0.5)
    check("judge commits a complete thought at a short pause", first.isEmpty && out.first?.reason == "judged")
}
do {
    let judge = FakeJudge("anfangen")
    let s = segmenter(judge: judge.callAsFunction)
    let hyp = words("dass wir morgen nicht um neun.")
    _ = await s.step(now: 2.5, words: hyp, silence: 0)
    let out = await s.step(now: 3, words: hyp, silence: 0.5)
    check("judge holds a clause still waiting for its verb", out.isEmpty)
}
do {
    let judge = FakeJudge()
    let s = segmenter(judge: judge.callAsFunction)
    _ = await s.step(now: 2.5, words: words("dass wir morgen"), silence: 0.5)
    let notAsked = judge.asked.isEmpty
    let hyp = words("dass wir morgen nicht")
    _ = await s.step(now: 2, words: hyp, silence: 0.5)
    _ = await s.step(now: 2, words: hyp, silence: 0.5)
    _ = await s.step(now: 2.1, words: hyp, silence: 0.6)
    check("judge is not asked about unstable words, or twice about the same",
          notAsked && judge.asked == ["dass wir morgen nicht"], "\(judge.asked)")
}
do {
    let judge = FakeJudge("gemacht")
    let s = segmenter({ $0.softSegment = 4 }, judge: judge.callAsFunction)
    let hyp = words("weil wir das morgen um neun, und nicht später gemacht haben wollten und so")
    _ = await s.step(now: 5, words: hyp, silence: 0)
    let out = await s.step(now: 5.5, words: hyp, silence: 0)
    check("judge vetoes a comma cut that would strand the verb", out.isEmpty)
}
do {
    let judge = FakeJudge("gemacht")
    let s = segmenter({ $0.softSegment = 3; $0.maxSegment = 4 }, judge: judge.callAsFunction)
    let hyp = words("wir haben das alles gestern gemacht") + words("weil es", start: 2.6)
        + words("nötig war und dann noch", start: 3.8)
    _ = await s.step(now: 6, words: hyp, silence: 0)
    let out = await s.step(now: 6.5, words: hyp, silence: 0)
    check("forced cut prefers the point the judge accepts",
          out.map(\.text) == ["wir haben das alles gestern gemacht"] && out.first?.reason == "force", "\(out)")
}
do {
    let judge = FakeJudge()
    let s = segmenter({ $0.softSegment = 3; $0.maxSegment = 4; $0.hardSegment = 6 }, judge: judge.callAsFunction)
    var hyp = words("wir haben das alles gestern gemacht weil es nötig war und dann noch so")
    _ = await s.step(now: 6, words: hyp, silence: 0)
    let waited = await s.step(now: 6.5, words: hyp, silence: 0).isEmpty
    hyp = words("wir haben das alles gestern gemacht weil es nötig war und dann noch so und weiter")
    _ = await s.step(now: 7, words: hyp, silence: 0)
    let out = await s.step(now: 7.5, words: hyp, silence: 0)
    check("forced cut waits rather than cut where the judge refuses, up to the hard limit",
          waited && out.first?.reason == "force")
}
do {
    let s = segmenter()
    _ = await s.step(now: 3, words: words("Yeah yeah okay so we went home and slept. And then"), silence: 0)
    let out = await s.step(now: 3.5, words: words("Yeah yeah yeah okay so we went home and slept. And then"), silence: 0)
    check("an early flicker does not hold back a later sentence end",
          out.map(\.text) == ["Yeah yeah yeah okay so we went home and slept."], "\(out)")
}
do {
    let s = segmenter()
    _ = await s.step(now: 3, words: words("Ich habe gestern das Auto. Und dann"), silence: 0)
    let out = await s.step(now: 3.5, words: words("Mich hat gestern der Hund. Und dann"), silence: 0)
    check("a mostly rewritten window is not stable", out.isEmpty)
}
do {
    let s = segmenter()
    let hyp = words("Nem tudom")
    _ = await s.step(now: 1, words: hyp, silence: 0)
    let out = await s.step(now: 2.5, words: hyp, silence: 0)
    check("a long gap after the last word is a pause, whatever the VAD hears", out.first?.reason == "pause")
}

// MARK: clock times

for (source, expected) in [
    ("Wir fangen um halb elf an.", "Wir fangen um 10:30 an."),
    ("erst um halb 11 anfangen", "erst um 10:30 anfangen"),
    ("Es ist halb eins.", "Es ist 12:30."),
    ("We beginnen om half negen.", "We beginnen om 8:30."),
    ("Das Konzert ist um drei viertel zehn.", "Das Konzert ist um 9:45."),
    ("um dreiviertel acht", "um 7:45"),
    ("Wir treffen uns um Viertel vor sechs.", "Wir treffen uns um 5:45."),
    ("Ik ben er om kwart voor twaalf.", "Ik ben er om 11:45."),
    ("um 19 Uhr halb 8", "um 19 Uhr 7:30"),
] {
    check("clock: \(source)", Clock.normalise(source) == expected, Clock.normalise(source))
}
for text in ["Viertel nach vier", "kwart over twee", "Das ist nur halb so viel.", "Ich habe die Hälfte gegessen.", "halb voll"] {
    check("clock leaves alone: \(text)", Clock.normalise(text) == text, Clock.normalise(text))
}

// MARK: echoes

check("garbled English repeated is an echo",
      echoes("I put on the table go see the bag then.", "I put on the table go see the bag then.")
          && echoes("She comes in hug me. Where is my cat?", "She comes in, hugs me. Where's my cat?"))
check("a real translation is not an echo",
      !echoes("Nie, nie moja, twoja pewnie.", "No, it's not mine, probably yours.")
          && !echoes("Dziękuję. Gdzie później się oddać?", "Thank you. Where to meet up later?"))

// MARK: language evidence

let here = ["en", "pl", "hu", "nl"]
for text in ["A tudom, de a nyelvedől.", "Nem tudom, volám használt that volami.", "Chciałem poprosić o zapalniczkę.",
             "Ale tego nie wiesz.", "Dat is gezellig, toch?"] {
    check("evidence lets through: \(text)", Languages.evidence(text, here) == true)
}
for text in ["Почему единицы на подниму?", "Não é nada pois.", "¿Dónde está el baño?"] {
    check("evidence turns away: \(text)", Languages.evidence(text, here) == false)
}
check("Cyrillic is fine where Russian is expected", Languages.evidence("Почему единицы на подниму?", ["en", "ru"]) != false)
check("no signs either way leaves it to the model", Languages.evidence("Apoi zulas.", here) == nil)
check("language list reads naturally", Languages.list(["pl", "hu", "nl"]) == "Polish, Hungarian and Dutch")

// MARK: catch-up

let backlog = Backlog()
check("catch-up: brief past 1.5 s, faster past 1 s, at most 1.3x",
      !backlog.brief(1.4) && backlog.brief(1.5) && backlog.pace(1) == 1 && abs(backlog.pace(2) - 1.1) < 1e-9
          && backlog.pace(10) == 1.3)

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
