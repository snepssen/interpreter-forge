import Foundation

/// The languages Parakeet v3 transcribes, and what the text of a piece says
/// about which of them it is in. Port of `languages.py` and `evidence()`.
public enum Languages {
    public static let names: [String: String] = [
        "bg": "Bulgarian", "cs": "Czech", "da": "Danish", "de": "German", "el": "Greek", "en": "English",
        "es": "Spanish", "et": "Estonian", "fi": "Finnish", "fr": "French", "hr": "Croatian", "hu": "Hungarian",
        "it": "Italian", "lt": "Lithuanian", "lv": "Latvian", "mt": "Maltese", "nl": "Dutch", "pl": "Polish",
        "pt": "Portuguese", "ro": "Romanian", "ru": "Russian", "sk": "Slovak", "sl": "Slovenian", "sv": "Swedish",
        "uk": "Ukrainian",
    ]
    static let scripts = ["bg": "CYRILLIC", "ru": "CYRILLIC", "uk": "CYRILLIC", "el": "GREEK"]  // others: LATIN

    /// Letters that all but give a language away; á, é, ö... are shared too widely.
    static let letters: [String: Set<Character>] = [
        "pl": "łąęśźć", "hu": "őű", "cs": "řěů", "sk": "ľĺŕ", "ro": "ășț", "es": "ñ¿¡",
        "pt": "ãõ", "de": "ß", "fr": "œ", "da": "æø", "lt": "ėįųū", "lv": "āēīūļņķģ", "mt": "ħġ",
    ].mapValues { Set($0) }

    /// Everyday words English doesn't share: "nem", "tudom" mark Hungarian even
    /// when the rest came out garbled. Others fall back to asking the model.
    static let words: [String: Set<String>] = [
        "pl": ["nie", "tak", "jest", "że", "się", "ale", "czy", "już", "jak", "tylko", "mnie", "wiesz",
               "dobra", "dobrze", "teraz", "jestem", "jesteś", "mówię", "może", "tego", "tym", "był", "była"],
        "hu": ["nem", "igen", "hogy", "egy", "meg", "csak", "van", "nincs", "tudom", "azt", "és", "már",
               "akkor", "persze", "nagyon", "szia", "mert", "vagy", "volt", "lesz", "itt", "ott", "nekem"],
        "nl": ["ik", "het", "een", "niet", "dat", "wat", "maar", "ook", "nog", "toch", "zijn", "heb",
               "hebt", "jij", "wij", "geen", "veel", "gezellig", "lekker", "kijk", "zeg"],
    ]

    /// "Polish, Hungarian and Dutch" for ["pl", "hu", "nl"].
    public static func list(_ codes: [String]) -> String {
        let words = codes.compactMap { names[$0] }
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }

    /// What the text itself says about being in one of `codes`: true, false, or
    /// nil when it doesn't say and the model has to be asked.
    public static func evidence(_ text: String, _ codes: [String]) -> Bool? {
        let expectedScripts = Set(codes.map { scripts[$0] ?? "LATIN" })
        let lower = text.lowercased()
        let found = lower.filter(\.isLetter)
        let foreign = found.filter { !expectedScripts.contains(script($0)) }.count
        if foreign >= 2 { return false }  // Cyrillic for Polish, say
        let letterSet = Set(found)
        let wordSet = Set(lower.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        if codes.contains(where: { !(letters[$0] ?? []).isDisjoint(with: letterSet)
                                   || !(words[$0] ?? []).isDisjoint(with: wordSet) }) {
            return true
        }
        if letters.contains(where: { !codes.contains($0.key) && !$0.value.isDisjoint(with: letterSet) }) {
            return false  // ã, ñ, ß... and nothing of ours
        }
        return nil
    }

    static func script(_ ch: Character) -> String {
        let name = ch.unicodeScalars.first?.properties.name ?? ""
        return String(name.split(separator: " ").first ?? "")
    }
}
