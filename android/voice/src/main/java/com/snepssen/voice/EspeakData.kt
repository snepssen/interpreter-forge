package com.snepssen.voice

import android.content.Context
import java.io.File

/**
 * espeak-ng's data, as every snepssen voice was trained with it (voice-core's
 * copy, packaged as assets). espeak-ng reads a folder, so the assets are
 * copied into the app's files once per app version.
 */
object EspeakData {
    private const val ROOT = "espeak-ng-data"

    fun directory(context: Context): File {
        val target = File(context.filesDir, ROOT)
        val stamp = File(context.filesDir, "$ROOT.version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (target.isDirectory && stamp.takeIf { it.exists() }?.readText() == version) return target
        target.deleteRecursively()
        copy(context, ROOT, target)
        stamp.writeText(version)
        return target
    }

    private fun copy(context: Context, asset: String, to: File) {
        val children = context.assets.list(asset).orEmpty()
        if (children.isEmpty()) {
            to.parentFile?.mkdirs()
            context.assets.open(asset).use { input -> to.outputStream().use { input.copyTo(it) } }
        } else {
            to.mkdirs()
            for (child in children) copy(context, "$asset/$child", File(to, child))
        }
    }
}
