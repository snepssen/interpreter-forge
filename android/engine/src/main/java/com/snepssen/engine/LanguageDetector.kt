package com.snepssen.engine

import android.content.Context
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextClassifier
import android.view.textclassifier.TextLanguage
import com.snepssen.core.Languages

/**
 * Which language a piece is in, from Android's own on-device detector, as the
 * iPhone app asks Apple's: nothing to download, and the same answer whichever
 * translation model is loaded. On 76 short everyday lines of known language
 * both named 75; on 2,341 lines from the kitchen recording and the phone
 * tests they agree on 97%, and most of the rest are English the Apple
 * detector was unsure of.
 *
 * Android's detector can't be restricted to the languages wanted, so its
 * guesses are read among them: a wanted language's confidence is its share of
 * the wanted ones, with any unwanted guess more likely than it counted
 * against it too. Arabic at 0.67 over English at 0.19 ("Ale to ale.") is not
 * sure English.
 */
class LanguageDetector(context: Context) {
    data class Guess(val code: String, val confidence: Double)  // ISO 639-1, as Parakeet and TranslateGemma use

    private val classifier: TextClassifier? =
        runCatching { context.getSystemService(TextClassificationManager::class.java)?.textClassifier }.getOrNull()

    /** Europe's languages and its neighbours': what the people this is for speak. */
    private val candidates = Languages.names.keys + setOf("no", "ca", "tr")

    /**
     * Never on the main thread: the system's classifier may block. A phone
     * whose classifier is missing or fails gives no guess: then nothing is
     * taken as already understood, and a "translation" that only repeats its
     * source is caught as an echo instead.
     */
    fun guess(text: String): Guess? {
        if (text.isBlank()) return null
        val result = runCatching { classifier?.detectLanguage(TextLanguage.Request.Builder(text).build()) }.getOrNull() ?: return null
        val all = (0 until result.localeHypothesisCount).map { i ->
            val locale = result.getLocale(i)
            val code = when (locale.language) { "nb", "nn" -> "no"; else -> locale.language }
            code to result.getConfidenceScore(locale).toDouble()
        }
        val wanted = all.filter { it.first in candidates }
        val (code, score) = wanted.maxByOrNull { it.second } ?: return null
        val against = wanted.sumOf { it.second } + all.filter { it.first !in candidates && it.second > score }.sumOf { it.second }
        return Guess(code, if (against > 0) score / against else 0.0)
    }
}
