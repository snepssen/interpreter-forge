package com.snepssen.engine

import android.os.Debug
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snepssen.hearing.Recognizer
import com.snepssen.voice.PolyglotVoice
import com.snepssen.voice.Voice
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.random.Random

/**
 * The engine under abuse: a long session for leaks and drift, stopping and
 * starting at random moments, a model closed under a translation, hostile
 * text, silence and noise. Models as for LiveTest (scripts/test-engine.sh
 * with -e class com.snepssen.engine.StressTest); the report goes to
 * files/stress-report.txt.
 */
@RunWith(AndroidJUnit4::class)
class StressTest {
    companion object {
        private val context = InstrumentationRegistry.getInstrumentation().targetContext
        private val files = context.filesDir
        private val args = InstrumentationRegistry.getArguments()
        private val model = TranslationModel.valueOf(args.getString("model") ?: TranslationModel.TRANSLATE_GEMMA.name)
        private val report = StringBuilder()
        lateinit var recognizer: Recognizer
        lateinit var voice: Voice
        lateinit var linguist: Linguist

        fun say(line: String) { synchronized(report) { report.appendLine(line) }; println(line); flush() }
        private fun flush() = synchronized(report) { File(files, "stress-report.txt").writeText(report.toString()) }

        @BeforeClass @JvmStatic fun load() {
            recognizer = Recognizer(File(files, "parakeet"), threads = Threads.hearing)
            voice = PolyglotVoice.load(context)
            linguist = Linguist(context, model, File(files, model.file.name), languages = emptyList())
            say("${model.title}, ${Runtime.getRuntime().availableProcessors()} cores")
        }

        @AfterClass @JvmStatic fun unload() { linguist.close(); recognizer.close(); voice.close() }

        /** Megabytes the process holds, all of it: Java, native, mapped models. */
        fun memoryMB(): Int { val info = Debug.MemoryInfo(); Debug.getMemoryInfo(info); return info.totalPss / 1024 }

        fun recording(language: String) = Wav.read16k(File(files, "samples/snep_$language.wav"))
    }

    private class Tally {
        val lags = mutableListOf<Pair<Double, Double>>()  // (when, lag)
        var committed = 0; var spoken = 0; var silent = 0
        val failures = mutableListOf<String>()
    }

    private fun run(audio: FloatArray, pipeline: Pipeline, tally: Tally, quiet: Boolean = true) {
        pipeline.start(Recording(audio), audible = false) { event ->
            synchronized(tally) {
                when (event) {
                    is PipelineEvent.Committed -> tally.committed++
                    is PipelineEvent.Silent -> tally.silent++
                    is PipelineEvent.Interpreted -> {
                        tally.spoken++
                        event.lags.forEach { tally.lags += event.playStart to it }
                        if (!quiet) say("  → ${event.translation}")
                    }
                    is PipelineEvent.Failed -> tally.failures += event.message
                    is PipelineEvent.Hearing -> {}
                }
            }
        }
    }

    @Test fun longSession() {
        val minutes = args.getString("minutes")?.toDouble() ?: 10.0
        // Every recording, into English, with three seconds of quiet between: a conversation.
        val gap = FloatArray(16_000 * 3)
        val one = listOf("pl", "hu", "de", "nl", "fr", "es", "it", "en").map { recording(it) + gap }
        val loop = mutableListOf<FloatArray>()
        while (loop.sumOf { it.size } < minutes * 60 * 16_000) loop += one
        val audio = FloatArray(loop.sumOf { it.size }).also { out -> var at = 0; loop.forEach { it.copyInto(out, at); at += it.size } }
        say("\n== long session: %.1f minutes".format(audio.size / 16_000.0 / 60))
        linguist.setLanguages(emptyList(), "en"); voice.language = "en"
        val before = memoryMB()
        val pipeline = Pipeline(recognizer, linguist, voice, Bundled.vad(context))
        val tally = Tally()
        val memory = mutableListOf<Int>()
        val sampler = Thread {
            try { while (true) { Thread.sleep(30_000); memory += memoryMB(); say("  at %d s: %d MB, %d spoken, lag so far median %.1f s".format(
                memory.size * 30, memory.last(), tally.spoken, synchronized(tally) { tally.lags.map { it.second }.sorted().let { if (it.isEmpty()) 0.0 else it[it.size / 2] } })) } }
            catch (_: InterruptedException) {}
        }.apply { start() }
        run(audio, pipeline, tally)
        runBlocking { pipeline.finish() }
        sampler.interrupt()
        pipeline.close()
        val lags = tally.lags.sortedBy { it.first }.map { it.second }
        val third = lags.size / 3
        fun median(l: List<Double>) = l.sorted()[l.size / 2]
        val early = median(lags.take(third)); val late = median(lags.takeLast(third))
        say("long session: ${tally.committed} pieces heard, ${tally.spoken} spoken, ${tally.silent} silent; " +
            "lag median %.1f s in the first third, %.1f s in the last; worst %.1f s".format(early, late, lags.max()))
        say("memory: %d MB before, %s during, %d MB after".format(before, memory.joinToString(" "), memoryMB()))
        assertTrue(tally.failures.toString(), tally.failures.isEmpty())
        // No drift: the interpreter keeps up rather than falling further behind.
        assertTrue("lag grew from %.1f to %.1f s".format(early, late), late < early + 3)
        // No leak: what the session held in its middle it still holds at its end, give or take.
        if (memory.size >= 4) {
            val settled = memory[memory.size / 3]
            assertTrue("memory grew from $settled to ${memory.last()} MB", memory.last() < settled + 150)
        }
    }

    @Test fun stopAndStartAtRandom() {
        say("\n== stop and start at random")
        linguist.setLanguages(emptyList(), "en"); voice.language = "en"
        val random = Random(7)
        val audio = recording("pl")
        repeat(20) { round ->
            val pipeline = Pipeline(recognizer, linguist, voice, Bundled.vad(context))
            val tally = Tally()
            linguist.forget()
            run(audio, pipeline, tally)
            Thread.sleep(random.nextLong(200, 6_000))
            pipeline.stop()
            runBlocking { withTimeout(30_000) { pipeline.finish() } }
            pipeline.close()
            assertTrue("round $round: ${tally.failures}", tally.failures.isEmpty())
        }
        say("20 rounds stopped at random moments: no failure, nothing hung")
    }

    @Test fun modelClosedUnderATranslation() {
        say("\n== a model closed under a translation")
        // The shared model itself: two of them don't fit beside each other,
        // which is why the app lets one go before loading the next.
        val own = linguist
        val result = arrayOfNulls<Throwable>(1)
        val worker = Thread {
            try { repeat(5) { own.translate("Nie wiem, czy dzisiaj przyjdzie, bo pociąg z Krakowa jest odwołany.") } }
            catch (e: Throwable) { result[0] = e }
        }.apply { start() }
        Thread.sleep(1_500)
        own.close()  // waits for the translation under way; the next one must refuse, not crash
        worker.join(60_000)
        say("closed mid-run: the next translation said \"${result[0]?.message}\"")
        linguist = Linguist(context, model, File(files, model.file.name), languages = emptyList())
        assertTrue("expected a refusal, got ${result[0]}", result[0] is IllegalStateException)
    }

    @Test fun hostileText() {
        say("\n== hostile text")
        linguist.setLanguages(emptyList(), "en"); voice.language = "en"
        val long = List(600) { listOf("i", "wtedy", "powiedziałem", "mu", "że", "nie", "przyjdę") [it % 7] }.joinToString(" ")
        val lines = listOf("", " ", "...", "?!", "😀🔥🙈", "Jó, menjünk 😀", "你好，我们明天见。", "مرحبا كيف حالك", "Привет, как дела?",
                           "a".repeat(3_000), long, "1234567890", "\u0000\u0001", "Ünïcödé çhàrâctérs, ñ, ß, ø, ł, ő")
        for (text in lines) {
            val label = text.take(30).replace("\u0000", "\\0").replace("\u0001", "\\1")
            val gate = linguist.gate(text)
            val outcome = try {
                val out = if (gate == null) linguist.translate(text) else "(${gate.name.lowercase()}, not translated)"
                val samples = voice.speak(out)
                "\"${out.take(60)}\" (%.1f s of speech)".format(samples.size / voice.sampleRate.toDouble())
            } catch (e: UnclearTranslation) { "unclear: ${e.message}" }
            say("  [$label…] ${text.length} chars → $outcome")
        }
        say("all ${lines.size} survived")
    }

    @Test fun silenceAndNoise() {
        say("\n== silence and noise")
        linguist.setLanguages(emptyList(), "en"); voice.language = "en"
        val random = Random(3)
        val silence = FloatArray(16_000 * 30)
        val hiss = FloatArray(16_000 * 30) { (random.nextFloat() - 0.5f) * 0.02f }
        val loud = FloatArray(16_000 * 15) { (random.nextFloat() - 0.5f) * 1.6f }  // clipping white noise
        for ((name, audio) in listOf("30 s of silence" to silence, "30 s of hiss" to hiss, "15 s of loud noise" to loud)) {
            val pipeline = Pipeline(recognizer, linguist, voice, Bundled.vad(context))
            val tally = Tally()
            run(audio, pipeline, tally, quiet = false)
            runBlocking { pipeline.finish() }
            pipeline.close()
            say("  $name: ${tally.committed} pieces heard, ${tally.spoken} spoken")
            assertTrue(tally.failures.toString(), tally.failures.isEmpty())
            if (audio === silence) assertEquals("silence was heard as speech", 0, tally.committed)
        }
    }
}
