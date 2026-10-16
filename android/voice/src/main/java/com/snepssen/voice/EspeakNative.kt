package com.snepssen.voice

/** The three espeak-ng calls, from voice_jni.cpp. */
internal object EspeakNative {
    init { System.loadLibrary("voicecore") }
    @JvmStatic external fun initialize(dataPath: String): Int
    @JvmStatic external fun setVoice(name: String): Int
    /** Clauses as `phonemes \u001f terminator \u001f 0|1 \u001e`, in order. */
    @JvmStatic external fun clauses(text: String): String
}
