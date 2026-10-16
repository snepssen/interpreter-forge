package com.snepssen.core

import java.util.regex.Pattern

/**
 * Narrow checks for errors reproduced in recording runs. These do not score
 * translation accuracy or infer missing words from an ambiguous transcript.
 */
object TranslationQuality {
    private fun regex(p: String) = Pattern.compile(p, Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE)
    private val ambiguousTime = regex("""\b(?:verso\s+le|alle|sono\s+le|ore)\s+\d{1,2}\s*[-–]\s*\d{1,2}\b""")
    /**
     * A translator talking about the text instead of translating it: a refusal,
     * or a remark on its language (field test, everyday Polish swearing).
     * "I'm sorry" alone is a translation of "Przepraszam" and is not caught.
     */
    private val commentary = regex(
        """\b(?:I|we)(?:'|’)?(?:m| am)?\s+(?:can(?:'|’)?t|cannot|won(?:'|’)?t|will not|unable to|not able to|not comfortable)\b[^.]{0,60}\b(?:translat|help with|assist|provide|fulfil|repeat|reproduce|comply)""" +
        """|\b(?:offensive|inappropriate|vulgar|derogatory|explicit|hateful|profane|obscene)\s+(?:language|content|term|terms|word|words|slur|slurs|remark|remarks)\b""" +
        """|\b(?:contains|contain|containing|includes|uses)\s+(?:profanity|swear(?:ing| words)|offensive|vulgar|explicit)""" +
        """|\bas an AI\b|\blanguage model\b|\bI(?:'|’)?m an AI\b""")
    private val placeholder = regex("""\[(?:name|insert[^\]]*|unknown[^\]]*)\]""")

    fun concern(source: String, translation: String? = null): String? {
        if (ambiguousTime.matcher(source).find()) return "The clock time was unclear in speech recognition. Please repeat it."
        if (translation == null) return null
        if (translation.isBlank()) return "No translation was produced. Please repeat this piece."
        if (commentary.matcher(translation).find()) return "The translator commented instead of translating, so this piece was skipped."
        val m = placeholder.matcher(translation)
        while (m.find()) {
            if (!source.contains(m.group(), ignoreCase = true)) return "The translation invented a placeholder. Please repeat this piece."
        }
        return null
    }
}
