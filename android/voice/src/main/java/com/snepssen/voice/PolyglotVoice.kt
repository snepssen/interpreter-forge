package com.snepssen.voice

import android.content.Context
import java.io.File

/**
 * The polyglot snepssen voice the app ships with. ONNX Runtime reads a file,
 * so the model and its config are copied out of the assets once per app
 * version, as espeak-ng's data is.
 */
object PolyglotVoice {
    private const val MODEL = "snepssen-polyglot.onnx"

    fun file(context: Context): File {
        val folder = File(context.filesDir, "voice")
        val stamp = File(folder, "version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        val model = File(folder, MODEL)
        if (model.exists() && stamp.takeIf { it.exists() }?.readText() == version) return model
        folder.mkdirs()
        for (name in listOf(MODEL, "$MODEL.json")) {
            val part = File(folder, "$name.part")
            context.assets.open("voice/$name").use { input -> part.outputStream().use { input.copyTo(it) } }
            part.renameTo(File(folder, name))
        }
        stamp.writeText(version)
        return model
    }

    /** The voice, ready to speak. */
    fun load(context: Context) = Voice(file(context), EspeakData.directory(context))
}
