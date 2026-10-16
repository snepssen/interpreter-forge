package com.snepssen.translating

import android.content.Context
import java.io.File

/**
 * A GGUF model on llama.cpp, greedy. The context is kept between calls, and
 * a prompt that starts as the last one did is only read from where it differs.
 *
 * `noSpacePrefix`: tokenize text after a special token without a leading "▁",
 * as Hugging Face does for EuroLLM; its GGUF asks for one (see translator_jni.cpp).
 *
 * Every call holds the model; once closed, calls throw rather than reach
 * freed memory (a translation already queued when the model is switched).
 */
class Llm(context: Context, model: File, val contextSize: Int = 2048, threads: Int = 4, noSpacePrefix: Boolean = false) : AutoCloseable {
    private var handle: Long

    init {
        synchronized(Llm::class.java) {
            if (!initialized) { LlamaNative.initialize(context.applicationInfo.nativeLibraryDir); initialized = true }
        }
        handle = LlamaNative.load(model.absolutePath, contextSize, threads, noSpacePrefix)
        require(handle != 0L) { "llama.cpp could not load ${model.name}" }
    }

    private fun open(): Long = handle.takeIf { it != 0L } ?: throw IllegalStateException("The translation model was closed.")

    @Synchronized fun tokenize(text: String): IntArray = LlamaNative.tokenize(open(), text.toByteArray())

    /**
     * Greedy continuation; `firstLine` stops at the end of the first non-empty
     * line. A cap reached inside a character leaves half of it: dropped.
     */
    @Synchronized fun generate(prompt: String, maxTokens: Int, firstLine: Boolean = true): String =
        String(LlamaNative.generate(open(), prompt.toByteArray(), maxTokens, firstLine), Charsets.UTF_8).trimEnd('�')

    @Synchronized override fun close() {
        if (handle == 0L) return
        LlamaNative.free(handle)
        handle = 0L
    }

    private companion object { var initialized = false }
}
