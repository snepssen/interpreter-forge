package com.snepssen.voice

import java.text.Normalizer
import java.util.Locale
import java.util.regex.Pattern

/**
 * espeak-ng, corrected: the phonemizer the polyglot snepssen voice was trained
 * through. voice-core's Polyphon.swift (itself voice-polyglot's polyphon.py)
 * in Kotlin, rule for rule, held to the same id fixtures by PolyphonTest.
 *
 * Everything works on code points, never on characters as displayed: c plus a
 * combining cedilla and the precomposed ç must stay different symbols.
 */
object Polyphon {
    /** The languages the voice was trained on, as the app offers them. */
    val trained = listOf("en", "pl", "hu", "de", "nl", "fr", "es", "it")

    /** espeak-ng's voice for a language; any other code is tried as is. */
    fun espeakVoice(language: String) = if (language == "en") "en-us" else language

    /** Android's regex is ICU, Unicode-aware for \\b, \\s and \\p{L} by default, like
     *  NSRegularExpression; UNICODE_CHARACTER_CLASS is the JVM's switch for it, which
     *  Android refuses. */
    private fun regex(pattern: String, caseInsensitive: Boolean = false): Pattern =
        Pattern.compile(pattern, if (caseInsensitive) Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE else 0)

    // spelling, before espeak-ng
    private val spelling = mapOf(
        "hu" to listOf(
            regex("""\b(mé|ju|cse|olá|plé)h\b""", caseInsensitive = true) to "$1",  // silent final h
            regex("nb") to "mb",                                                     // n before b is m
            regex("szs") to "ss",                                                    // sz + s: long s
        ),
    )

    // IPA, after espeak-ng
    private fun cp(vararg points: Int) = points
    private val ipa = mapOf(
        "de" to listOf(
            cp('c'.code, 0x327) to cp(0xE7),  // ç precomposed: c alone is Hungarian ty
            cp(0x25C) to cp(0x250),           // -er: ɜ -> ɐ
            cp(0x27E) to cp(0x250),           // r after a vowel: ɾ -> ɐ
            cp('r'.code) to cp(0x281),        // r before a vowel: uvular ʁ
        ),
        "nl" to listOf(
            cp(0x263) to cp(0x3C7),           // g: ɣ -> χ
            cp('x'.code) to cp(0x3C7),        // ch: x -> χ
            cp(0x27E) to cp(0x280),           // r: ɾ -> ʀ
            cp('r'.code) to cp(0x280),        // r: r -> ʀ
        ),
        "it" to listOf(
            cp(0x27E) to cp('r'.code),        // one trilled r
        ),
    )

    private const val VOWELS = "aeiouyæøœɐɑɒɔəɘɛɜɞɤɨɪɯɵɶʉʊʌʏ"
    private const val MARKS = "ˈˌːˑ̯̩̪̺̻̝̃̊ʲʷˤ˞"
    /** A doubled consonant, which espeak-ng writes two ways, as one: Cː. */
    private val double = regex("""([^\s$VOWELS$MARKS'\-,.?!;:])\1(?!ː)""")
    private val flags = regex("""\([^)]+\)""")
    private val sentenceBreak = regex("""(?<=[.!?])\s+""")
    private val word = regex("""[\p{L}\p{Nl}\p{No}]+(?:['’-][\p{L}\p{Nl}\p{No}]+)*""")
    private val dz = regex("dzi|dź|dż|dz")

    /** Sentences of code points, as the voice's training data was made. */
    fun sentences(text: String, language: String, espeak: EspeakPhonemizer): List<IntArray> {
        var given = text
        for ((pattern, template) in spelling[language].orEmpty()) given = pattern.matcher(given).replaceAll(template)
        val raw = plain(given, espeak)
        if (language !in trained || language == "en") return raw
        val textSentences = split(given.trim())
        return raw.mapIndexed { n, sentence ->
            var ipaPoints = sentence
            if (language == "pl" && n < textSentences.size) {
                val textWords = matches(word, textSentences[n])
                val ipaWords = splitOnSpace(ipaPoints)
                ipaPoints = if (textWords.size == ipaWords.size) {
                    joinWithSpace(textWords.zip(ipaWords).map { (w, i) -> polishHardDz(w, i) })
                } else {
                    polishHardDz(textWords.joinToString(" "), ipaPoints)  // clitics fused: as one word
                }
            }
            for ((from, to) in ipa[language].orEmpty()) ipaPoints = replaceAll(from, to, ipaPoints)
            val string = double.matcher(String(ipaPoints, 0, ipaPoints.size)).replaceAll("$1ː")
            symbols(string)
        }
    }

    /** espeak-ng's sentences, uncorrected: piper's EspeakPhonemizer.phonemize. */
    fun plain(text: String, espeak: EspeakPhonemizer): List<IntArray> {
        val all = mutableListOf<IntArray>()
        var sentence = IntArray(0)
        for (clause in espeak.clauses(text)) {
            var phonemes = flags.matcher(clause.phonemes).replaceAll("") + clause.terminator
            if (clause.terminator in setOf(",", ":", ";")) phonemes += " "
            sentence += Normalizer.normalize(phonemes, Normalizer.Form.NFD).codePoints().toArray()
            if (clause.endOfSentence) { all += sentence; sentence = IntArray(0) }
        }
        if (sentence.isNotEmpty()) all += sentence
        return all
    }

    /** Ids for the voice: `^`, each symbol and a pad, `$`, per sentence, chained. */
    fun ids(sentences: List<IntArray>, map: Map<String, IntArray>): IntArray {
        val pad = map["_"] ?: IntArray(0)
        val out = ArrayList<Int>()
        for (sentence in sentences) {
            out += (map["^"] ?: IntArray(0)).toList(); out += pad.toList()
            for (point in sentence) {
                val id = map[String(Character.toChars(point))] ?: continue
                out += id.toList(); out += pad.toList()
            }
            out += (map["$"] ?: IntArray(0)).toList()
        }
        return out.toIntArray()
    }

    /** One symbol per code point, except a precomposed ç, which the table has. */
    private fun symbols(ipa: String): IntArray =
        replaceAll(intArrayOf('c'.code, 0x327), intArrayOf(0xE7), Normalizer.normalize(ipa, Normalizer.Form.NFD).codePoints().toArray())

    /**
     * espeak-ng reads every Polish dz as soft dʑ. Each dʑ in a word's IPA comes,
     * in order, from one of dzi / dź / hard dz in its spelling; the hard ones
     * become dz. If the counts disagree the word is left alone.
     */
    fun polishHardDz(word: String, ipa: IntArray): IntArray {
        val kinds = matches(dz, word.lowercase(Locale.ROOT)).filter { it != "dż" }.map { it == "dz" }
        val hits = (0 until ipa.size - 1).filter { ipa[it] == 'd'.code && ipa[it + 1] == 0x291 }
        if (true !in kinds || hits.size != kinds.size) return ipa
        val out = ipa.copyOf()
        for ((hard, at) in kinds.zip(hits)) if (hard) out[at + 1] = 'z'.code
        return out
    }

    private fun matches(pattern: Pattern, text: String): List<String> {
        val m = pattern.matcher(text); val out = mutableListOf<String>()
        while (m.find()) out += m.group()
        return out
    }

    /** Python's re.split(r"(?<=[.!?])\s+", text), empty pieces dropped. */
    private fun split(text: String) = sentenceBreak.split(text).filter { it.isNotEmpty() }

    private fun splitOnSpace(points: IntArray): List<IntArray> {
        val out = mutableListOf<IntArray>(); var start = 0
        for (i in points.indices) if (points[i] == ' '.code) { out += points.copyOfRange(start, i); start = i + 1 }
        out += points.copyOfRange(start, points.size)
        return out
    }

    private fun joinWithSpace(parts: List<IntArray>): IntArray {
        val out = ArrayList<Int>()
        parts.forEachIndexed { i, p -> if (i > 0) out += ' '.code; out += p.toList() }
        return out.toIntArray()
    }

    /** `str.replace` on code points: left to right, non-overlapping. */
    private fun replaceAll(from: IntArray, to: IntArray, points: IntArray): IntArray {
        val out = ArrayList<Int>(points.size); var i = 0
        while (i < points.size) {
            if (i + from.size <= points.size && (from.indices).all { points[i + it] == from[it] }) {
                out += to.toList(); i += from.size
            } else { out += points[i]; i += 1 }
        }
        return out.toIntArray()
    }
}
