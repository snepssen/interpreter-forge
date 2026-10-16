package com.snepssen.engine

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Where downloaded models live, in the app's own files, and how they get
 * there: each file pinned to a revision, resumed where a dropped connection
 * left it, and kept only if it matches its SHA-256.
 */
object ModelStore {
    fun location(context: Context, model: TranslationModel) = File(context.filesDir, model.file.name)

    fun isDownloaded(context: Context, model: TranslationModel) = location(context, model).length() == model.file.size

    fun hasHearing(context: Context) =
        Hearing.parakeet.all { File(Hearing.parakeetFolder(context), it.name).length() == it.size }

    /** Download `files` into `folder`; `progress` gets the fraction done, over all of them. */
    suspend fun download(folder: File, files: List<ModelFile>, progress: (Double) -> Unit) = withContext(Dispatchers.IO) {
        folder.mkdirs()
        val total = files.sumOf { it.size }.toDouble()
        var before = 0L
        for (file in files) {
            val out = File(folder, file.name)
            if (out.length() != file.size) {
                val part = File(folder, file.name + ".part")
                fetch(file, part) { done -> progress((before + done) / total) }
                if (!verify(part, file.sha256)) {
                    part.delete()
                    throw IOException("${file.name} arrived damaged (its SHA-256 doesn't match). Try again.")
                }
                if (!part.renameTo(out)) throw IOException("Couldn't save ${file.name}.")
            }
            before += file.size
            progress(before / total)
        }
    }

    suspend fun download(context: Context, model: TranslationModel, progress: (Double) -> Unit) =
        download(context.filesDir, listOf(model.file), progress)

    suspend fun downloadHearing(context: Context, progress: (Double) -> Unit) =
        download(Hearing.parakeetFolder(context), Hearing.parakeet, progress)

    fun delete(context: Context, model: TranslationModel) {
        location(context, model).delete()
        File(context.filesDir, model.file.name + ".part").delete()
    }

    /** Bytes still to fetch for these. */
    fun remaining(folder: File, files: List<ModelFile>) =
        files.sumOf { f -> if (File(folder, f.name).length() == f.size) 0L else f.size - File(folder, f.name + ".part").length() }

    private suspend fun fetch(file: ModelFile, part: File, progress: (Long) -> Unit) {
        var redirects = 0
        var url = URL(file.url)
        while (true) {
            val have = part.length()
            if (have == file.size) return
            if (have > file.size) part.delete()
            val connection = url.openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false  // across hosts, Range must be sent again
            connection.connectTimeout = 20_000
            connection.readTimeout = 60_000
            if (part.length() > 0) connection.setRequestProperty("Range", "bytes=${part.length()}-")
            try {
                when (val code = connection.responseCode) {
                    in 300..399 -> {
                        val next = connection.getHeaderField("Location") ?: throw IOException("A redirect without a destination.")
                        if (++redirects > 8) throw IOException("Too many redirects.")
                        url = URL(url, next)
                        continue
                    }
                    200, 206 -> {
                        val append = code == 206
                        connection.inputStream.use { input ->
                            FileOutputStream(part, append).use { output ->
                                val buffer = ByteArray(1 shl 16)
                                var done = if (append) part.length() else 0L
                                var reported = 0L
                                while (true) {
                                    kotlin.coroutines.coroutineContext.ensureActive()
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    output.write(buffer, 0, n)
                                    done += n
                                    if (done - reported > 1 shl 20) { progress(done); reported = done }
                                }
                                progress(done)
                            }
                        }
                        if (part.length() != file.size) throw IOException("The download of ${file.name} was cut short. Try again to resume it.")
                        return
                    }
                    416 -> { part.delete(); continue }  // the partial file is no use: start over
                    else -> throw IOException("The server answered $code for ${file.name}.")
                }
            } finally { connection.disconnect() }
        }
    }

    private fun verify(file: File, sha256: String): Boolean {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 20)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } == sha256
    }
}
