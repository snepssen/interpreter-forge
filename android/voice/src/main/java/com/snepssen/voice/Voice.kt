package com.snepssen.voice

import java.io.File

/**
 * The interpreter's voice: speaks `language`. A polyglot voice goes through
 * Polyphon, one `^`...`$` run per sentence as in its training data, each
 * language at its own length scale; any other Piper voice through plain
 * espeak-ng. `pace` divides the length scale, for catching up.
 */
class Voice(model: File, private val espeakData: File) : AutoCloseable {
    private val piper = PiperModel(model)
    private val phonemizers = mutableMapOf<String, EspeakPhonemizer>()
    val sampleRate get() = piper.sampleRate
    val languages get() = piper.polyglot?.languages ?: listOf("en")
    val isPolyglot get() = piper.polyglot != null

    @Volatile var language = "en"

    init { phonemizer(piper.espeakVoice) }

    private var closed = false

    /**
     * Mono samples at `sampleRate`, peak-normalised to 0.9. Characters beyond
     * the Basic Multilingual Plane (emoji, now and then in a translation) are
     * left out: nothing to say, and JNI would hand espeak-ng broken UTF-8.
     */
    @Synchronized fun speak(text: String, pace: Double = 1.0): FloatArray {
        check(!closed) { "The voice was closed." }
        val text = text.filterNot { it.isSurrogate() }
        var scale = piper.lengthScale
        // In pieces of a few sentences: one inference's memory grows with its
        // length, and a long merged translation in one pass (40 s of speech)
        // took a phone past 4 GB. Each sentence is its own ^...$ run either way.
        val runs: List<IntArray> = piper.polyglot?.let { polyglot ->
            scale *= polyglot.lengthScale[language] ?: 1.0
            val sentences = Polyphon.sentences(text, language, phonemizer(Polyphon.espeakVoice(language)))
                .flatMap { split(it) }
            group(sentences).map { Polyphon.ids(it, piper.phonemeIdMap) }
        } ?: split(phonemizer(piper.espeakVoice).phonemize(text).codePoints().toArray())
            .map { piper.ids(String(it, 0, it.size)) }
        val parts = runs.filter { it.size > 3 }.map { piper.infer(it, piper.noiseScale, scale / pace, piper.noiseW) }
        if (parts.isEmpty()) return FloatArray(0)
        val samples = FloatArray(parts.sumOf { it.size }).also { out -> var at = 0; parts.forEach { it.copyInto(out, at); at += it.size } }
        val peak = samples.maxOfOrNull { kotlin.math.abs(it) } ?: 0f
        if (peak > 1e-8f) { val gain = 0.9f / peak; for (i in samples.indices) samples[i] *= gain }
        return samples
    }

    /** A sentence longer than [PIECE] symbols, cut at spaces. */
    private fun split(points: IntArray): List<IntArray> {
        if (points.size <= PIECE) return listOf(points)
        val out = mutableListOf<IntArray>(); var start = 0
        while (start < points.size) {
            var end = minOf(points.size, start + PIECE)
            if (end < points.size) (end - 1 downTo start + PIECE / 2).firstOrNull { points[it] == ' '.code }?.let { end = it + 1 }
            out += points.copyOfRange(start, end); start = end
        }
        return out
    }

    /** Consecutive sentences, up to [PIECE] symbols to an inference. */
    private fun group(sentences: List<IntArray>): List<List<IntArray>> {
        val out = mutableListOf<MutableList<IntArray>>(); var size = 0
        for (s in sentences) {
            if (out.isEmpty() || size + s.size > PIECE) { out += mutableListOf<IntArray>(); size = 0 }
            out.last() += s; size += s.size
        }
        return out
    }

    private companion object { const val PIECE = 400 }

    @Synchronized fun polyglotIds(text: String, language: String): IntArray =
        Polyphon.ids(Polyphon.sentences(text, language, phonemizer(Polyphon.espeakVoice(language))), piper.phonemeIdMap)

    private fun phonemizer(espeakVoice: String) =
        phonemizers.getOrPut(espeakVoice) { EspeakPhonemizer(espeakData, espeakVoice) }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        piper.close()
    }
}
