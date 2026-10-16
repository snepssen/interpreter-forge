package com.snepssen.translating

/** llama.cpp, from translator_jni.cpp. Text crosses as UTF-8 bytes. */
internal object LlamaNative {
    init { System.loadLibrary("translator") }
    @JvmStatic external fun initialize(nativeLibDir: String)
    @JvmStatic external fun load(path: String, contextSize: Int, threads: Int, noSpacePrefix: Boolean): Long
    @JvmStatic external fun tokenize(handle: Long, text: ByteArray): IntArray
    @JvmStatic external fun generate(handle: Long, prompt: ByteArray, maxTokens: Int, firstLine: Boolean): ByteArray
    @JvmStatic external fun free(handle: Long)
}
