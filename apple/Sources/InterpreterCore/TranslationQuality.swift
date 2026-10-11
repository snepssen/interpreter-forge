import Foundation

/// Narrow checks for errors reproduced in recording runs. These do not score
/// translation accuracy or infer missing words from an ambiguous transcript.
public enum TranslationQuality {
    private static let ambiguousTime = try! NSRegularExpression(
        pattern: #"\b(?:verso\s+le|alle|sono\s+le|ore)\s+\d{1,2}\s*[-–]\s*\d{1,2}\b"#,
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
        for match in placeholder.matches(in: translation, range: NSRange(translation.startIndex..., in: translation)) {
            let value = (translation as NSString).substring(with: match.range)
            if source.range(of: value, options: [.caseInsensitive]) == nil {
                return "The translation invented a placeholder. Please repeat this piece."
            }
        }
        return nil
    }
}
