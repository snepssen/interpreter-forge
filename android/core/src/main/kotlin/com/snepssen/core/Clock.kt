package com.snepssen.core

import java.util.regex.Pattern

/**
 * Clock times that count toward the next hour, rewritten as digits before
 * translation: German and Dutch "halb elf" / "half elf" is 10:30, and a 4B
 * model reads it as 11:30 every time. The iPhone app's Clock, ported.
 */
object Clock {
    private val hours = mapOf(
        // German
        "eins" to 1, "zwei" to 2, "drei" to 3, "vier" to 4, "fünf" to 5, "sechs" to 6, "sieben" to 7,
        "acht" to 8, "neun" to 9, "zehn" to 10, "elf" to 11, "zwölf" to 12,
        // Dutch
        "een" to 1, "één" to 1, "twee" to 2, "vijf" to 5, "zes" to 6, "zeven" to 7, "negen" to 9, "tien" to 10, "twaalf" to 12,
    )

    /** (pattern, minutes past the hour before), all counting toward the named hour. */
    private val rules: List<Pair<Pattern, Int>> = run {
        val names = hours.keys.sortedWith(compareByDescending<String> { it.length }.thenByDescending { it })
        val hour = "(\\d{1,2}|" + names.joinToString("|") + ")"
        listOf(
            "\\b(?:halb|half)\\s+$hour\\b" to 30,
            "\\b(?:drei\\s*viertel|dreiviertel)\\s+$hour\\b" to 45,
            "\\b(?:viertel|kwart)\\s+(?:vor|voor)\\s+$hour\\b" to 45,
        ).map { (p, m) -> Pattern.compile(p, Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE) to m }
    }

    fun normalise(text: String): String {
        var out = text
        for ((rule, minutes) in rules) {
            val m = rule.matcher(out)
            val sb = StringBuilder(); var cursor = 0
            while (m.find()) {
                sb.append(out, cursor, m.start())
                val n = hour(m.group(1))
                sb.append(if (n != null) "${if (n > 1) n - 1 else 12}:" + "%02d".format(minutes) else m.group())
                cursor = m.end()
            }
            out = sb.append(out, cursor, out.length).toString()
        }
        return out
    }

    private fun hour(word: String): Int? {
        val n = word.toIntOrNull() ?: hours[word.lowercase()] ?: return null
        return n.takeIf { it in 1..24 }
    }
}
