package com.snepssen.engine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snepssen.hearing.Recognizer
import com.snepssen.voice.PolyglotVoice
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * snepssen's recordings through the whole live loop, at the pace they were
 * spoken, as tcrun plays them through the Mac's: hearing, cutting, the gate,
 * translating, the voice. Models are copied into this app's files by
 * scripts/test-engine.sh; the run is written to files/live-report.txt.
 */
@RunWith(AndroidJUnit4::class)
class LiveTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val files = context.filesDir
    private val report = StringBuilder()
    private fun say(line: String) { report.appendLine(line); println(line) }

    @Test fun recordingsAreInterpreted() {
        // Instrumentation arguments: model, hearing and translating threads, and which recordings.
        val args = InstrumentationRegistry.getArguments()
        val model = TranslationModel.valueOf(args.getString("model") ?: TranslationModel.TRANSLATE_GEMMA.name)
        val hearingThreads = args.getString("hearing")?.toInt() ?: Threads.hearing
        val translatingThreads = args.getString("translating")?.toInt() ?: Threads.translating
        val started = System.nanoTime()
        val recognizer = Recognizer(File(files, "parakeet"), threads = hearingThreads)
        val voice = PolyglotVoice.load(context)
        val linguist = Linguist(context, model, File(files, model.file.name), languages = emptyList(), threads = translatingThreads)
        say("${model.title}: loaded in %.1f s; hearing on %d threads, translating on %d, of %d cores".format(
            (System.nanoTime() - started) / 1e9, hearingThreads, translatingThreads, Runtime.getRuntime().availableProcessors()))
        // Into English from each language, and English into Polish.
        val only = args.getString("recordings")?.split(",")
        val runs = (listOf("pl", "hu", "de", "nl", "fr", "es", "it").map { it to "en" } + ("en" to "pl"))
            .filter { only == null || it.first in only }
        val lags = mutableListOf<Double>()
        var spoken = 0
        try {
            for ((from, into) in runs) {
                val audio = File(files, "samples/snep_$from.wav").takeIf { it.exists() } ?: continue
                linguist.setLanguages(emptyList(), into)
                voice.language = into
                linguist.warmUp()
                say("\n== snep_$from into $into")
                val pipeline = Pipeline(recognizer, linguist, voice, Bundled.vad(context), takeTurns = args.getString("turns") != "false")
                val texts = mutableMapOf<Int, String>()
                pipeline.start(Recording(to16k(audio)), audible = false) { event ->
                    synchronized(report) {
                        when (event) {
                            is PipelineEvent.Committed -> {
                                texts[event.segment.index] = event.segment.text
                                say("[%6.2f–%6.2f] %-8s │ %s".format(event.segment.start, event.segment.end, event.segment.reason, event.segment.text))
                            }
                            is PipelineEvent.Silent -> say("  #${event.index} ${event.why.name.lowercase()}, not spoken" +
                                (event.translation?.let { ": $it" } ?: ""))
                            is PipelineEvent.Interpreted -> {
                                lags += event.lags; spoken++
                                say("  → ${event.translation}   (lag %s)".format(event.lags.joinToString { "%.1f s".format(it) }))
                            }
                            is PipelineEvent.Failed -> say("  FAILED: ${event.message}")
                            is PipelineEvent.Hearing -> {}
                        }
                    }
                }
                runBlocking { pipeline.finish() }
                assertTrue(pipeline.failure ?: "", pipeline.failure == null)
                pipeline.close()
            }
        } finally {
            linguist.close(); recognizer.close(); voice.close()
            if (lags.isNotEmpty()) {
                lags.sort()
                say("\n$spoken pieces spoken; lag median %.1f s, 90th percentile %.1f s, worst %.1f s".format(
                    lags[lags.size / 2], lags[(lags.size * 9 / 10).coerceAtMost(lags.size - 1)], lags.last()))
            }
            File(files, "live-report.txt").writeText(report.toString())
        }
        assertTrue("nothing was spoken", spoken > 0)
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
