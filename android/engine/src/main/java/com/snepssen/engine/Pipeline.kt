package com.snepssen.engine

import com.snepssen.core.Backlog
import com.snepssen.core.Segment
import com.snepssen.core.Segmenter
import com.snepssen.core.SegmenterConfig
import com.snepssen.core.echoes
import com.snepssen.hearing.Recognizer
import com.snepssen.hearing.SileroVad
import com.snepssen.voice.Voice
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.Executors

/** What happens to the speech, as it happens. */
sealed interface PipelineEvent {
    /** What is being heard and not yet committed. */
    data class Hearing(val text: String) : PipelineEvent
    data class Committed(val segment: Segment) : PipelineEvent
    /** Not spoken, and why; `translation` holds an echo or a clarification message. */
    data class Silent(val index: Int, val why: Silence, val translation: String? = null) : PipelineEvent
    /** Translated and queued to play at `playStart` (session seconds). `indices` are the
     *  pieces merged into it; `lags` each one's wait from its end to then. */
    data class Interpreted(val indices: List<Int>, val translation: String, val playStart: Double,
                           val lags: List<Double>, val pace: Double) : PipelineEvent
    /** Terminal failure: capture and playback have stopped. */
    data class Failed(val message: String) : PipelineEvent
}

/**
 * The live loop: one thread listens and cuts, another interprets what was
 * cut. The iPhone app's Pipeline. On a phone both share the CPU: speech
 * recognition and translation each take a few cores. Neither model Android
 * runs judges when a thought is complete, so pieces are cut on pauses and
 * punctuation alone.
 */
class Pipeline(
    private val recognizer: Recognizer,
    private val linguist: Linguist,
    private val voice: Voice,
    private val vadModel: File,
    private val config: SegmenterConfig = SegmenterConfig(),
    private val backlog: Backlog? = Backlog(),
    /** Hearing and translating take turns at the CPU rather than share it. */
    private val takeTurns: Boolean = true,
) {
    // On the iPhone speech recognition runs on the Neural Engine and
    // translation on the GPU, side by side. Here both are on the CPU, and
    // sharing it is slower for both: every llama.cpp step waits for the last
    // of its threads, so a core lent to recognition stalls all of them
    // (TranslateGemma 4-10 s a line on an emulator's four cores sharing them,
    // 1.4-2.5 s taking turns; median lag 14.5 s against 5.8 s on snepssen's
    // recordings). Fair turns: a recognition pass (a quarter of a second)
    // never waits behind more than one translation.
    private val cpu = java.util.concurrent.locks.ReentrantLock(true)
    private inline fun <T> turn(work: () -> T): T = if (takeTurns) { cpu.lock(); try { work() } finally { cpu.unlock() } } else work()

    val clock = SessionClock()
    var speaker: Speaker? = null; private set
    private var source: AudioSource? = null
    /** Off for captions only: translations are shown but not voiced. */
    @Volatile var speaks = true
    @Volatile var failure: String? = null; private set
    val level get() = source?.buffer?.level ?: 0f
    private val inbox = Channel<Segment>(Channel.UNLIMITED)
    private val listening = Executors.newSingleThreadExecutor { Thread(it, "listening") }.asCoroutineDispatcher()
    private val interpreting = Executors.newSingleThreadExecutor { Thread(it, "interpreting") }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob())
    private var jobs = emptyList<Job>()
    @Volatile private var stopped = false

    /** Start on `source`; `audible` false keeps the schedule without playing, for a recording. */
    fun start(source: AudioSource, audible: Boolean, events: (PipelineEvent) -> Unit) {
        val speaker = Speaker(voice.sampleRate, audible, clock)
        val vad = SileroVad(vadModel)
        try {
            source.start()
            speaker.start()
        } catch (e: Exception) {
            source.stop(); speaker.stop(); vad.close()
            throw e
        }
        this.source = source
        this.speaker = speaker
        jobs = listOf(
            scope.launch(listening) { try { listen(source, vad, events) } finally { vad.close() } },
            scope.launch(interpreting) { interpret(speaker, events) },
        )
    }

    fun stop() {
        synchronized(this) { if (stopped) return; stopped = true }
        inbox.cancel()
        scope.cancel()
        source?.stop()
        speaker?.stop()
    }

    /** Wait until a recording has been heard to the end and everything in it said. */
    suspend fun finish() = jobs.joinAll()

    /** Let go of the threads, once stopped or finished. */
    fun close() {
        stop()
        listening.close()
        interpreting.close()
    }

    private fun fail(message: String, events: (PipelineEvent) -> Unit) {
        synchronized(this) { if (stopped || failure != null) return; failure = message }
        stop()
        events(PipelineEvent.Failed(message))
    }

    private companion object { const val TAG = "Pipeline" }

    // listening

    private suspend fun CoroutineScope.listen(source: AudioSource, vad: SileroVad, events: (PipelineEvent) -> Unit) {
        val buffer = source.buffer
        val segmenter = Segmenter(config, judge = null)
        var vadAt = 0L
        var lastHop = 0.0
        fun commit(segments: List<Segment>) {
            for (segment in segments) {
                val decided = segment.copy(decidedAt = clock.now())
                events(PipelineEvent.Committed(decided))
                inbox.trySend(decided)
            }
        }
        while (isActive) {
            val ended = source.finished
            val heard = buffer.count
            try {
                while (vadAt + SileroVad.FRAME <= heard) {
                    vad.push(buffer.read(vadAt, vadAt + SileroVad.FRAME), (vadAt + SileroVad.FRAME) / 16_000.0)
                    vadAt += SileroVad.FRAME
                }
            } catch (e: Exception) {
                if (isActive) fail("Detecting speech: ${e.message}", events)
                return
            }
            val now = heard / 16_000.0
            if (ended) {  // a recording ran out: say what is left, then let the interpreter finish
                try {
                    val start = segmenter.windowStart()
                    val words = turn { recognizer.transcribe(buffer.read((start * 16_000).toLong(), heard), start) }
                    ensureActive()
                    commit(segmenter.flush(now, segmenter.newWords(words)))
                    inbox.close()
                } catch (e: CancellationException) { throw e
                } catch (e: Exception) { fail("Speech recognition: ${e.message}", events) }
                return
            }
            if (now - lastHop < config.hop) { delay(30); continue }
            lastHop = now
            if (vad.lastSpeech <= segmenter.mark) {
                segmenter.advanceIdle(now)
                buffer.drop(((segmenter.windowStart() - 1) * 16_000).toLong())
                continue
            }
            val start = segmenter.windowStart()
            try {
                val asked = System.nanoTime()
                val words = segmenter.newWords(turn { recognizer.transcribe(buffer.read((start * 16_000).toLong(), heard), start) })
                Log.d(TAG, "heard %.1f s of audio in %d ms".format(now - start, (System.nanoTime() - asked) / 1_000_000))
                ensureActive()
                val silence = vad.silence(now)
                commit(segmenter.step(now, words, silence))
                events(PipelineEvent.Hearing(segmenter.pending.joinToString(" ") { it.text }))
                if (words.isEmpty() && (silence >= segmenter.longPauseThreshold() || now - start >= config.hardSegment)) {
                    segmenter.advanceIdle(now)
                }
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) {
                fail("Speech recognition: ${e.message}", events)
                return
            }
            buffer.drop(((segmenter.windowStart() - 1) * 16_000).toLong())  // keep a second spare
        }
    }

    // interpreting

    /** Everything waiting, or the next piece when it comes; null once closed. */
    private suspend fun takeAll(): List<Segment>? {
        val first = inbox.receiveCatching().getOrNull() ?: return null
        val all = mutableListOf(first)
        while (true) all += inbox.tryReceive().getOrNull() ?: break
        return all
    }

    private suspend fun CoroutineScope.interpret(speaker: Speaker, events: (PipelineEvent) -> Unit) {
        while (isActive) {
            val waiting = takeAll() ?: return
            val foreign = mutableListOf<Segment>()
            try {
                // Everything waiting goes as one: what the gate turns away set
                // aside, the rest merged into a single translation.
                for (segment in waiting) {
                    val why = linguist.gate(segment.text)
                    if (why != null) {
                        if (why == Silence.UNDERSTOOD) linguist.remember(segment.text)
                        events(PipelineEvent.Silent(segment.index, why))
                    } else foreign += segment
                }
                if (foreign.isEmpty()) continue
                val piece = Segment.combine(foreign)
                val asked = System.nanoTime()
                val translation = turn { linguist.translate(piece.text) }
                Log.d(TAG, "translated %d words in %d ms".format(piece.words.size, (System.nanoTime() - asked) / 1_000_000))
                ensureActive()
                if (echoes(piece.text, translation)) {
                    for (segment in foreign) events(PipelineEvent.Silent(segment.index, Silence.ECHO, translation))
                    continue
                }
                val pace = backlog?.pace(speaker.backlog) ?: 1.0
                val start = if (speaks) {
                    val samples = turn { voice.speak(translation, pace) }
                    ensureActive()
                    speaker.play(samples)
                } else clock.now()  // shown now: the lag is the wait for the text
                val ends = piece.parts.ifEmpty { listOf(piece.end) }
                events(PipelineEvent.Interpreted(foreign.map { it.index }, translation, start, ends.map { start - it }, pace))
            } catch (e: UnclearTranslation) {
                for (segment in foreign) events(PipelineEvent.Silent(segment.index, Silence.UNCLEAR, e.message))
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) {
                fail("Interpreting: ${e.message}", events)
                return
            }
        }
    }
}
