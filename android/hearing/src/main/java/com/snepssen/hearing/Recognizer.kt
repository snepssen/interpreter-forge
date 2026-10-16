package com.snepssen.hearing

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import java.io.File

/**
 * Parakeet TDT 0.6B v3 (25 European languages, punctuated) through sherpa-onnx.
 * The iPhone app runs the same model family through FluidAudio on the Neural
 * Engine; here it runs on the CPU. FluidAudio's script hint has no sherpa-onnx
 * counterpart, so the language filter works on the text alone.
 */
class Recognizer(modelDirectory: File, threads: Int = 4) : AutoCloseable {
    private val recognizer = OfflineRecognizer(
        null,
        OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16_000, featureDim = 80),
            modelConfig = OfflineModelConfig(
                transducer = OfflineTransducerModelConfig(
                    encoder = File(modelDirectory, "encoder.int8.onnx").path,
                    decoder = File(modelDirectory, "decoder.int8.onnx").path,
                    joiner = File(modelDirectory, "joiner.int8.onnx").path,
                ),
                tokens = File(modelDirectory, "tokens.txt").path,
                numThreads = threads,
                modelType = "nemo_transducer",
            ),
        ),
    )

    /** Words in `samples` (16 kHz mono), timed in stream seconds from `offset`. */
    @Synchronized fun transcribe(samples: FloatArray, offset: Double): List<Word> {
        if (samples.size < 16_000 * 3 / 10) return emptyList()
        val stream = recognizer.createStream()
        try {
            stream.acceptWaveform(samples, 16_000)
            recognizer.decode(stream)
            val result = recognizer.getResult(stream)
            val durations = result.durations
            return words(result.tokens.indices.map { i ->
                val start = result.timestamps.getOrElse(i) { 0f }.toDouble()
                val length = durations.getOrElse(i) { 0f }.toDouble()
                Token(result.tokens[i], start, start + length)
            }, offset)
        } finally { stream.release() }
    }

    override fun close() = recognizer.release()

    data class Token(val text: String, val start: Double, val end: Double)

    companion object {
        /**
         * Subword tokens joined into words: a word-boundary marker starts a new
         * one. Punctuation is often stamped well into the silence after a word,
         * so it adds to the text but not to the end time. The iPhone app's
         * Recognizer.words, line for line.
         */
        fun words(tokens: List<Token>, offset: Double): List<Word> {
            val words = mutableListOf<Word>()
            var text = ""; var start = 0.0; var end = 0.0
            fun flush() { val t = text.trim(); if (t.isNotEmpty()) words += Word(t, offset + start, offset + end) }
            for (token in tokens) {
                if (token.text.isEmpty() || token.text == "<blank>" || token.text == "<pad>") continue
                var piece = token.text.replace("▁", " ")
                if (piece.startsWith(" ") && text.trim().isNotEmpty()) { flush(); text = "" }
                if (text.trim().isEmpty()) { start = token.start; end = token.start; piece = piece.trim() }
                text += piece
                if (piece.any { it.isLetterOrDigit() }) end = token.end
            }
            flush()
            return words
        }
    }
}
