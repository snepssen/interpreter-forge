package com.snepssen.engine

import android.content.Context
import com.snepssen.core.Clock
import com.snepssen.core.Languages
import com.snepssen.core.TranslationQuality
import com.snepssen.translating.Llm
import com.snepssen.translating.Prompts
import java.io.File

/** Why a piece is not spoken. */
enum class Silence {
    UNDERSTOOD,  // already in the listener's language: kept as context
    LANGUAGE,  // in no language expected here: speech recognition went astray
    ECHO,  // a "translation" that only repeats its source: garbled English
    UNCLEAR,  // a reproduced quality problem: shown for clarification, not spoken
}

/** A translation not worth saying, and why: shown for clarification instead. */
class UnclearTranslation(message: String) : Exception(message)

/**
 * The translation model and what it is asked: translate this into the
 * listener's language. Whether a piece is already in the listener's language,
 * or in a language spoken here, is Android's language detector's call. The
 * iPhone app's Linguist, for the two models Android runs: neither takes
 * instructions, so neither judges when a thought is complete or summarises.
 *
 * llama.cpp keeps its attention cache between calls and reads only what
 * changed, so the earlier pieces carried as context cost little.
 */
class Linguist(
    context: Context,
    val model: TranslationModel,
    file: File,
    languages: List<String>,
    target: String = "en",
    threads: Int = Threads.translating,
) : AutoCloseable {
    private val llm = Llm(context, file, threads = threads, noSpacePrefix = model.noSpacePrefix)
    private val detector = LanguageDetector(context)
    /** The languages spoken here, if restricted; empty for any. */
    private var languages = languages.filter { it != target }
    /** The listener's language, which everything is interpreted into. */
    var target = target; private set
    private val history = mutableListOf<Prompts.Piece>()
    private val contextPieces = 3
    /** The last language named with confidence: a conversation rarely switches
     *  mid-thought, and two-word replies are where the detector is unsure. */
    private var lastLanguage: String? = null

    /** `languages` spoken here (empty for any), interpreted into `target`. */
    @Synchronized fun setLanguages(languages: List<String>, target: String) {
        val spoken = languages.filter { it != target }
        if (this.languages != spoken || this.target != target) forget()
        this.languages = spoken
        this.target = target
    }

    /** `text` in the listener's language. */
    @Synchronized fun translate(text: String): String {
        TranslationQuality.concern(text)?.let { throw UnclearTranslation(it) }
        val text = Clock.normalise(text)
        val language = source(text)
        if (history.size >= 2 * contextPieces) repeat(history.size - contextPieces) { history.removeAt(0) }
        // English seldom needs three times the tokens of its source; a cap keeps
        // an aside from being spoken and the listener from falling behind.
        // Other languages cost a tokenizer more per word than English does.
        val factor = if (target == "en") 3 else 4
        val cap = maxOf(24, factor * llm.tokenize(text).size)
        // Prompt and answer must fit the model's context, or llama.cpp stops
        // short: earlier pieces go first, then the cap. Pieces queued behind a
        // slow translation are merged, so one can be long.
        var context = history.filter { it.source != target }
        var prompt = prompt(context, language, text)
        var room = llm.contextSize - llm.tokenize(prompt).size
        while (room < cap && context.isNotEmpty()) {
            context = context.drop(1)
            prompt = prompt(context, language, text)
            room = llm.contextSize - llm.tokenize(prompt).size
        }
        if (room < 16) throw UnclearTranslation("Too much at once to translate. Please say it again in shorter pieces.")
        val out = spoken(llm.generate(prompt, minOf(cap, room)))
        TranslationQuality.concern(text, out)?.let { throw UnclearTranslation(it) }
        history += Prompts.Piece(language, text, out)
        return out
    }

    private fun prompt(context: List<Prompts.Piece>, language: String, text: String) = when (model) {
        // A piece kept as context because it was already in the listener's
        // language can't be "translated" into itself, so only translated pieces go in.
        TranslationModel.TRANSLATE_GEMMA -> Prompts.translateGemma(context, language, text, target)
        // One piece at a time: earlier pieces as context made a model this small echo them.
        TranslationModel.EURO_LLM -> Prompts.euroLLM(language, text, target)
    }

    /**
     * The language to translate from: the detector's answer when it is sure,
     * else the last one it was sure of, else its best guess. Never the
     * listener's own language: into English, Polish is the likeliest source,
     * into anything else English is.
     */
    private fun source(text: String): String {
        val guess = detector.guess(text)
        if (guess != null && guess.confidence >= 0.8 && guess.code != target) {
            lastLanguage = guess.code
            return guess.code
        }
        val fallback = if (target == "en") "pl" else "en"
        return lastLanguage ?: guess?.let { if (it.code == target) fallback else it.code } ?: fallback
    }

    /** Keep a piece that needed no translation as context for the ones that do. */
    @Synchronized fun remember(text: String) {
        history += Prompts.Piece(target, text, text)
        if (history.size > 2 * contextPieces) repeat(history.size - contextPieces) { history.removeAt(0) }
    }

    @Synchronized fun forget() {
        history.clear()
        lastLanguage = null
    }

    /** Read the prompt's fixed parts once, so the first real piece doesn't pay for it. */
    fun warmUp() {
        translate(if (target == "de") "Dzień dobry, jak się masz?" else "Hallo, wie geht's?")
        forget()
    }

    /**
     * Before translating: does this piece need it? The listener's own language
     * they understand; a language not spoken here (if restricted) is misheard.
     * The text's own signs come first, then the language detector.
     */
    @Synchronized fun gate(text: String): Silence? {
        val guess = detector.guess(text)
        if (guess != null && guess.code == target && guess.confidence >= 0.6) {
            // English has no letters outside ASCII: two of them and the
            // detector's "English" is a misreading.
            val foreign = text.count { it.isLetter() && it.code > 127 }
            if (target != "en" || foreign < 2) return Silence.UNDERSTOOD
        }
        if (languages.isEmpty()) return null
        val expected = listOf(target) + languages
        Languages.evidence(text, expected)?.let { return if (it) null else Silence.LANGUAGE }
        // Dropping real speech is the worse mistake: only a sure guess turns it away.
        if (guess != null && guess.confidence >= 0.8 && guess.code !in expected) return Silence.LANGUAGE
        return null
    }

    override fun close() = llm.close()

    companion object {
        private val gendered = Regex("""(\p{L}{3,})/(\p{L}+)""")

        /**
         * What is worth saying of an output: its first line, without quotes or a
         * note in brackets at the end ("(This is a somewhat unusual phrase – the
         * translation reflects…)", which TranslateGemma adds now and then). A
         * first line that only announces the rest ("Okay, here's the English
         * translation:") is skipped, and where both gendered forms are offered
         * ("chciałem/chciałam") the first is said: the voice would read the slash.
         */
        fun spoken(output: String): String {
            val lines = output.trim().split("\n").map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
            if (lines.size > 1 && lines[0].endsWith(":")) lines.removeAt(0)
            var out = lines.firstOrNull() ?: ""
            out = gendered.replace(out) { m ->
                val (first, second) = m.destructured
                if (first.take(3) == second.take(3)) first else "$first/$second"
            }
            val open = out.lastIndexOf('(')
            if (open > 0 && out.endsWith(")") && out.substring(open).split(" ").count { it.isNotEmpty() } > 4) out = out.substring(0, open)
            return out.trim { it in "\"“” " }.trim()
        }
    }
}
