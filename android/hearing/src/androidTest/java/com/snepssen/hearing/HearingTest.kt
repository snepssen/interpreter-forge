package com.snepssen.hearing

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * snepssen's eight test recordings through Silero and Parakeet on the device:
 * what was heard, against what was said, and how long it took. The models and
 * recordings are pushed into this app's files by scripts/test-hearing.sh.
 */
@RunWith(AndroidJUnit4::class)
class HearingTest {
    private val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir

    /** Same audio as the Mac benchmark; preserves every transcript for WER scoring. */
    @Test fun polyglotBenchmark() {
        org.junit.Assume.assumeTrue("push the optional benchmark corpus first", File(files, "benchmark").isDirectory)
        val audioFiles = File(files, "benchmark").listFiles()?.filter { it.extension == "wav" }?.sortedBy { it.name }
            ?: error("push the benchmark corpus first")
        assertTrue("expected 32 benchmark clips", audioFiles.size == 32)
        val report = File(files, "benchmark.jsonl")
        report.writeText("")
        Recognizer(File(files, "parakeet")).use { recognizer ->
            for (audio in audioFiles) {
                val samples = to16k(audio)
                val started = System.nanoTime()
                val words = recognizer.transcribe(samples, 0.0)
                val seconds = (System.nanoTime() - started) / 1e9
                val row = org.json.JSONObject()
                    .put("file", audio.name)
                    .put("model", "android-parakeet-ultra-int8")
                    .put("reference", File(audio.parentFile, audio.nameWithoutExtension + ".txt").readText())
                    .put("hypothesis", words.joinToString(" ") { it.text })
                    .put("audio_seconds", samples.size / 16_000.0)
                    .put("recognition_seconds", seconds)
                report.appendText(row.toString() + "\n")
                println("benchmark ${audio.name}: ${words.joinToString(" ") { it.text }}")
                assertTrue("invalid timing", words.all { it.start.isFinite() && it.end.isFinite() && it.end >= it.start })
            }
        }
    }

    @Test fun snepssenIsHeard() {
        val recognizer = Recognizer(File(files, "parakeet"))
        val report = StringBuilder()
        var total = 0.0; var count = 0
        for (lang in listOf("en", "pl", "hu", "de", "nl", "fr", "es", "it")) {
            val audio = File(files, "samples/snep_$lang.wav").takeIf { it.exists() } ?: continue
            val samples = to16k(audio)
            val vad = SileroVad(File(files, "silero_vad_v5.onnx"))
            var speechFrames = 0
            var i = 0
            while (i + SileroVad.FRAME <= samples.size) {
                if (vad.push(samples.copyOfRange(i, i + SileroVad.FRAME), (i + SileroVad.FRAME) / 16_000.0)) speechFrames++
                i += SileroVad.FRAME
            }
            vad.close()
            val started = System.nanoTime()
            val words = recognizer.transcribe(samples, 0.0)
            val ms = (System.nanoTime() - started) / 1e6
            val said = File(files, "samples/snep_$lang.txt").readText()
            val accuracy = accuracy(said, words.joinToString(" ") { it.text })
            total += accuracy; count++
            val line = "hearing $lang: %.0f%% of words, %.1f s of audio in %.0f ms, speech frames %d of %d\n  heard: %s"
                .format(accuracy * 100, samples.size / 16_000.0, ms, speechFrames, samples.size / SileroVad.FRAME, words.joinToString(" ") { it.text })
            println(line); report.appendLine(line)
            assertTrue("$lang: voice detection heard nothing", speechFrames > 10)
            assertTrue("$lang: words have no timing", words.all { it.end >= it.start })
        }
        recognizer.close()
        File(files, "hearing-report.txt").writeText(report.toString())
        assertTrue("too few recordings", count == 8)
        assertTrue("recognition heard too little: ${total / count}", total / count > 0.75)
    }

    /** Word accuracy: the share of the said words found in order in what was heard. */
    private fun accuracy(said: String, heard: String): Double {
        fun words(t: String) = t.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        val a = words(said); val b = words(heard)
        val lcs = Array(a.size + 1) { IntArray(b.size + 1) }
        for (x in a.indices.reversed()) for (y in b.indices.reversed())
            lcs[x][y] = if (a[x] == b[y]) lcs[x + 1][y + 1] + 1 else maxOf(lcs[x + 1][y], lcs[x][y + 1])
        return lcs[0][0] / a.size.toDouble()
    }

    /** A 16-bit mono WAV at any rate, to 16 kHz floats. */
    private fun to16k(file: File): FloatArray {
        val bytes = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        val rate = bytes.getInt(24)
        var pos = 12
        while (pos + 8 <= bytes.limit()) {
            val id = String(ByteArray(4) { bytes.get(pos + it) }); val size = bytes.getInt(pos + 4)
            if (id == "data") break
            pos += 8 + size
        }
        val n = bytes.getInt(pos + 4) / 2
        val src = FloatArray(n) { bytes.getShort(pos + 8 + it * 2) / 32768f }
        val step = rate / 16_000.0
        return FloatArray((n / step).toInt()) { k -> val x = k * step; val i = x.toInt(); val f = (x - i).toFloat()
            src[i] + (src[minOf(i + 1, n - 1)] - src[i]) * f }
    }
}
