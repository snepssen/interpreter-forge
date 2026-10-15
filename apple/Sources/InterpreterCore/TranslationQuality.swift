import Foundation

/// Narrow checks for errors reproduced in recording runs. These do not score
/// translation accuracy or infer missing words from an ambiguous transcript.
public enum TranslationQuality {
    private static let ambiguousTime = try! NSRegularExpression(
        pattern: #"\b(?:verso\s+le|alle|sono\s+le|ore)\s+\d{1,2}\s*[-–]\s*\d{1,2}\b"#,
        options: [.caseInsensitive])
    /// A translator talking about the text instead of translating it: a
    /// refusal, or a remark on its language. Heard in a field test on
    /// everyday Polish swearing, where the voice spoke it instead of the
    /// translation. It is caught by what only commentary says: declining to
    /// translate or help, naming the text's language as offensive, speaking
    /// as an AI. "I'm sorry" alone is a translation of "Przepraszam" and is
    /// not caught.
    private static let commentary = try! NSRegularExpression(
        pattern: #"\b(?:I|we)(?:'|’)?(?:m| am)?\s+(?:can(?:'|’)?t|cannot|won(?:'|’)?t|will not|unable to|not able to|not comfortable)\b[^.]{0,60}\b(?:translat|help with|assist|provide|fulfil|repeat|reproduce|comply)"#
            + #"|\b(?:offensive|inappropriate|vulgar|derogatory|explicit|hateful|profane|obscene)\s+(?:language|content|term|terms|word|words|slur|slurs|remark|remarks)\b"#
            + #"|\b(?:contains|contain|containing|includes|uses)\s+(?:profanity|swear(?:ing| words)|offensive|vulgar|explicit)"#
            + #"|\bas an AI\b|\blanguage model\b|\bI(?:'|’)?m an AI\b"#,
        options: [.caseInsensitive])
    private static let placeholder = try! NSRegularExpression(
        pattern: #"\[(?:name|insert[^\]]*|unknown[^\]]*)\]"#, options: [.caseInsensitive])

    public static func concern(source: String, translation: String? = nil) -> String? {
        if ambiguousTime.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
            return "The clock time was unclear in speech recognition. Please repeat it."
        }
        guard let translation else { return nil }
        if translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No translation was produced. Please repeat this piece."
        }
        if commentary.firstMatch(in: translation, range: NSRange(translation.startIndex..., in: translation)) != nil {
            return "The translator commented instead of translating, so this piece was skipped."
        }
        for match in placeholder.matches(in: translation, range: NSRange(translation.startIndex..., in: translation)) {
            let value = (translation as NSString).substring(with: match.range)
            if source.range(of: value, options: [.caseInsensitive]) == nil {
                return "The translation invented a placeholder. Please repeat this piece."
            }
        }
        return nil
    }
}
