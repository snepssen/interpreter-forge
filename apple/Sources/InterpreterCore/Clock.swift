import Foundation

/// Clock times that count toward the next hour, rewritten as digits before
/// translation: German and Dutch "halb elf" / "half elf" is 10:30, and a 4B
/// model reads it as 11:30 every time, prompt or no prompt. Port of `clock.py`.
public enum Clock {
    static let hours: [String: Int] = [
        // German
        "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7,
        "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12,
        // Dutch
        "een": 1, "één": 1, "twee": 2, "vijf": 5, "zes": 6, "zeven": 7, "negen": 9, "tien": 10, "twaalf": 12,
    ]

    /// (pattern, minutes past the hour before), all counting toward the named hour.
    static let rules: [(NSRegularExpression, Int)] = {
        let hour = "(\\d{1,2}|" + hours.keys.sorted { ($0.count, $0) > ($1.count, $1) }.joined(separator: "|") + ")"
        return [
            ("\\b(?:halb|half)\\s+" + hour + "\\b", 30),
            ("\\b(?:drei\\s*viertel|dreiviertel)\\s+" + hour + "\\b", 45),
            ("\\b(?:viertel|kwart)\\s+(?:vor|voor)\\s+" + hour + "\\b", 45),
        ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }
    }()

    public static func normalise(_ text: String) -> String {
        var text = text
        for (rule, minutes) in rules {
            let ns = text as NSString
            var out = ""
            var cursor = 0
            for match in rule.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let word = ns.substring(with: match.range(at: 1))
                if let n = hour(word) {
                    out += "\(n > 1 ? n - 1 : 12):" + String(format: "%02d", minutes)
                } else {
                    out += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            text = out + ns.substring(from: cursor)
        }
        return text
    }

    static func hour(_ word: String) -> Int? {
        let n = Int(word) ?? hours[word.lowercased()]
        guard let n, (1...24).contains(n) else { return nil }
        return n
    }
}
