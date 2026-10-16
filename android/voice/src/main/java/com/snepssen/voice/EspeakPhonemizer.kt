package com.snepssen.voice

import java.io.File
import java.text.Normalizer

/**
 * Text to phonemes, via espeak-ng: voice-core's EspeakPhonemizer in Kotlin.
 * Each app's policy is an option, as there: `respellings` (Gateway Forge's)
 * and whether an em dash is given the spaces espeak needs to see it.
 * espeak-ng's state is process-global, so every call holds one lock.
 */
class EspeakPhonemizer(
    dataDirectory: File,
    private val voice: String,
    respellings: List<Pair<String, String>> = emptyList(),
    private val spacesEmDashes: Boolean = true,
) {
    data class Clause(val phonemes: String, val terminator: String, val endOfSentence: Boolean)

    class Failure(message: String) : Exception(message)

    private val respellings = respellings.sortedByDescending { it.first.length }

    init {
        synchronized(lock) {
            if (!initialized) {
                if (EspeakNative.initialize(dataDirectory.absolutePath) < 0) throw Failure("espeak-ng failed to initialize")
                initialized = true
            }
            select(voice)
        }
    }

    fun respelled(text: String): String = respellings.fold(text) { out, (term, to) -> out.replace(term, to) }

    fun clauses(text: String): List<Clause> = synchronized(lock) {
        select(voice)
        val given = respelled(text)
        EspeakNative.clauses(if (spacesEmDashes) spacedEmDashes(given) else given)
            .split('\u001e').filter { it.isNotEmpty() }
            .map { val f = it.split('\u001f'); Clause(f[0], f[1], f[2] == "1") }
    }

    /** One flattened phoneme string, a space after every terminator. */
    fun phonemize(text: String, dropFinalStop: Boolean = false): String {
        val result = StringBuilder()
        for (clause in clauses(text)) {
            var stripped = clause.phonemes
            while (true) {
                val open = stripped.indexOf('(')
                val close = if (open >= 0) stripped.indexOf(')', open) else -1
                if (open < 0 || close < 0) break
                stripped = stripped.removeRange(open, close + 1)
            }
            result.append(stripped).append(clause.terminator)
            if (clause.terminator.isNotEmpty()) result.append(' ')
        }
        var out = result.toString().trim()
        if (dropFinalStop && out.endsWith(".")) out = out.dropLast(1).trim()
        return Normalizer.normalize(out, Normalizer.Form.NFD)
    }

    companion object {
        private val lock = Any()
        private var initialized = false
        private var current: String? = null

        /** Under `lock`: setting a voice reloads its rules, so only on a change. */
        private fun select(voice: String) {
            if (current == voice) return
            if (EspeakNative.setVoice(voice) != 0) throw Failure("espeak-ng has no voice named $voice")
            current = voice
        }

        /** Give an em dash the spaces espeak needs in order to see it. */
        fun spacedEmDashes(text: String): String {
            if (!text.contains('—')) return text
            val out = StringBuilder()
            var pendingSpace = false
            for (ch in text) {
                if (ch == '—') {
                    if (!out.endsWith(" ")) out.append(' ')
                    out.append('—')
                    pendingSpace = true
                } else if (pendingSpace) {
                    out.append(if (ch == ' ') " " else " $ch")
                    pendingSpace = false
                } else {
                    out.append(ch)
                }
            }
            return out.toString()
        }
    }
}
