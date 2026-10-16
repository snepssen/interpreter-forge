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

    /** Mono samples at `sampleRate`, peak-normalised to 0.9. */
    @Synchronized fun speak(text: String, pace: Double = 1.0): FloatArray {
        var scale = piper.lengthScale
        val ids = piper.polyglot?.let { polyglot ->
            scale *= polyglot.lengthScale[language] ?: 1.0
            polyglotIds(text, language)
        } ?: piper.ids(phonemizer(piper.espeakVoice).phonemize(text))
        if (ids.size <= 3) return FloatArray(0)
        val samples = piper.infer(ids, piper.noiseScale, scale / pace, piper.noiseW)
        val peak = samples.maxOfOrNull { kotlin.math.abs(it) } ?: 0f
        if (peak > 1e-8f) { val gain = 0.9f / peak; for (i in samples.indices) samples[i] *= gain }
        return samples
    }

    @Synchronized fun polyglotIds(text: String, language: String): IntArray =
        Polyphon.ids(Polyphon.sentences(text, language, phonemizer(Polyphon.espeakVoice(language))), piper.phonemeIdMap)

    private fun phonemizer(espeakVoice: String) =
        phonemizers.getOrPut(espeakVoice) { EspeakPhonemizer(espeakData, espeakVoice) }

    override fun close() = piper.close()
}
