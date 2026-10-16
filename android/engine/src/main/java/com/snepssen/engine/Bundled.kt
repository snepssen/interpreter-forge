package com.snepssen.engine

import android.content.Context
import java.io.File

/** Files the app ships with, copied out of its assets once per app version for the libraries that read files. */
object Bundled {
    fun vad(context: Context) = file(context, "silero_vad_v5.onnx")

    private fun file(context: Context, name: String): File {
        val out = File(context.filesDir, name)
        val stamp = File(context.filesDir, "$name.version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (out.exists() && stamp.takeIf { it.exists() }?.readText() == version) return out
        val part = File(context.filesDir, "$name.part")
        context.assets.open(name).use { input -> part.outputStream().use { input.copyTo(it) } }
        part.renameTo(out)
        stamp.writeText(version)
        return out
    }
}
