/// The "translation" is mostly the source again: English the ASR garbled too
/// badly for the English check to pass, which the model then repeats. Over a
/// 70-minute conversation 40 of 101 interpreted pieces were this, and no real
/// translation scored above 0.6. Port of `echoes()`.
public func echoes(_ source: String, _ translation: String) -> Bool {
    func words(_ t: String) -> [String] {
        t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }
    return SequenceMatcher(words(source), words(translation)).ratio() >= 0.6
}
