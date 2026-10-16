package com.snepssen.engine

import android.app.ActivityManager
import android.content.Context
import java.io.File

/** A file the app downloads, pinned to a revision and held to its SHA-256. */
data class ModelFile(val name: String, val url: String, val size: Long, val sha256: String)

/**
 * A translation model, as GGUF for llama.cpp: the same two the iPhone app
 * offers on Android's terms. TranslateGemma is the standard; EuroLLM only for
 * a phone that can run nothing bigger.
 */
enum class TranslationModel(
    val title: String,
    val tagline: String,
    val summary: String,
    val file: ModelFile,
    /**
     * Total memory a phone needs to run it beside speech recognition, as
     * Android reports it (a 6 GB phone says about 5.6). llama.cpp maps the
     * model rather than reading it in, so its pages are the system's to drop
     * and reload; still, a guess until measured on real phones.
     */
    val memoryGB: Double,
    /** EuroLLM's tokenizer reads text after a special token without a leading space. */
    val noSpacePrefix: Boolean = false,
) {
    TRANSLATE_GEMMA(
        "TranslateGemma 4B", "Best translations",
        "Google's translation model: the most accurate, natural translations, 55 languages. Needs a phone with 6 GB or more.",
        ModelFile(
            "translategemma-4b-it.Q4_K_M.gguf",
            "https://huggingface.co/mradermacher/translategemma-4b-it-GGUF/resolve/d37868f759d2f817a43d28dd80cf9f982ffa62fd/translategemma-4b-it.Q4_K_M.gguf",
            2_489_909_760, "81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330"),
        memoryGB = 5.5,
    ),
    EURO_LLM(
        "EuroLLM 1.7B", "For 4 GB phones",
        "A small European model for phones that can't run TranslateGemma: rougher translations, the gist rather than every word, in the 24 EU languages.",
        ModelFile(
            "EuroLLM-1.7B-Instruct.Q4_K_M.gguf",
            "https://huggingface.co/mradermacher/EuroLLM-1.7B-Instruct-GGUF/resolve/2951f08f66429c934c8b01a94347161362430808/EuroLLM-1.7B-Instruct.Q4_K_M.gguf",
            1_045_157_088, "1cade17f491ea46a686dbee51fbd52442e0f001f102380c3b9d66b4a77f84093"),
        memoryGB = 3.5,
        noSpacePrefix = true,
    );

    companion object {
        /** The best model this phone can run, or null if it can run none. */
        fun recommended(context: Context): TranslationModel? = entries.firstOrNull { it.fits(context) }
    }

    /** Whether this phone has the memory for it (what Android reports, a little under what is fitted). */
    fun fits(context: Context): Boolean {
        val info = ActivityManager.MemoryInfo()
        context.getSystemService(ActivityManager::class.java).getMemoryInfo(info)
        return info.totalMem / 1e9 >= memoryGB
    }
}

/** What the app hears with and downloads beside the translator. */
object Hearing {
    /**
     * Parakeet Ultra: moondream's post-training of Parakeet v3 (CC-BY-4.0), in
     * sherpa-onnx's layout, Alexqwqw's export pinned as fetch-hearing.sh pins it.
     */
    private const val PARAKEET = "https://huggingface.co/Alexqwqw/parakeet-ultra-sherpa-onnx-int8/resolve/3e585661a664da28ff5d9293c5baaca22f930b8e"
    val parakeet = listOf(
        ModelFile("encoder.int8.onnx", "$PARAKEET/encoder.int8.onnx", 652_282_395, "4ef28650a81a38bc05124745dcfe776ff2bca7ac1d6009893a0f87d64bdf8b43"),
        ModelFile("decoder.int8.onnx", "$PARAKEET/decoder.int8.onnx", 11_845_275, "94373c6405c8149d1c9d1e9862514e0e3e88dab1c7de18fac9d5df9c6ba5efdd"),
        ModelFile("joiner.int8.onnx", "$PARAKEET/joiner.int8.onnx", 6_355_277, "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2"),
        ModelFile("tokens.txt", "$PARAKEET/tokens.txt", 93_939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
    )
    const val PARAKEET_FOLDER = "parakeet-ultra"

    fun parakeetFolder(context: Context) = File(context.filesDir, PARAKEET_FOLDER)
}
