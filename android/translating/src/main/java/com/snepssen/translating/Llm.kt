package com.snepssen.translating

import android.content.Context
import java.io.File

/**
 * A GGUF model on llama.cpp, greedy. The context is kept between calls, and
 * a prompt that starts as the last one did is only read from where it differs.
 */
/**
 * `noSpacePrefix`: tokenize text after a special token without a leading "▁",
 * as Hugging Face does for EuroLLM; its GGUF asks for one (see translator_jni.cpp).
 */
class Llm(context: Context, model: File, contextSize: Int = 2048, threads: Int = 4, noSpacePrefix: Boolean = false) : AutoCloseable {
    private val handle: Long

    init {
        synchronized(Llm::class.java) {
            if (!initialized) { LlamaNative.initialize(context.applicationInfo.nativeLibraryDir); initialized = true }
        }
        handle = LlamaNative.load(model.absolutePath, contextSize, threads, noSpacePrefix)
        require(handle != 0L) { "llama.cpp could not load ${model.name}" }
    }

    @Synchronized fun tokenize(text: String): IntArray = LlamaNative.tokenize(handle, text.toByteArray())

    /** Greedy continuation; `firstLine` stops at the end of the first non-empty line. */
    @Synchronized fun generate(prompt: String, maxTokens: Int, firstLine: Boolean = true): String =
        String(LlamaNative.generate(handle, prompt.toByteArray(), maxTokens, firstLine), Charsets.UTF_8)

    @Synchronized override fun close() = LlamaNative.free(handle)

    private companion object { var initialized = false }
}
