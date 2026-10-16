package com.snepssen.engine

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.SystemClock
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread
import kotlin.math.sqrt

/** Session seconds, from when it was made: the stream clock, give or take the input's latency. */
class SessionClock {
    private val started = SystemClock.elapsedRealtimeNanos()
    fun now() = (SystemClock.elapsedRealtimeNanos() - started) / 1e9
}

/**
 * Samples the microphone has delivered, 16 kHz mono, shared between the audio
 * thread that appends and the listener that reads.
 */
class SampleBuffer {
    private var samples = FloatArray(16_000 * 30)
    private var size = 0
    private var base = 0L  // stream index of samples[0]
    @Volatile var level = 0f; private set

    val count: Long @Synchronized get() = base + size

    @Synchronized fun append(block: FloatArray, n: Int = block.size) {
        if (n == 0) return
        var sum = 0f
        for (i in 0 until n) sum += block[i] * block[i]
        level = sqrt(sum / n)
        if (size + n > samples.size) samples = samples.copyOf(maxOf(samples.size * 2, size + n))
        System.arraycopy(block, 0, samples, size, n)
        size += n
    }

    /** Stream samples from `start` to `end`, whatever of them is still held. */
    @Synchronized fun read(start: Long, end: Long): FloatArray {
        val lo = (maxOf(start, base) - base).toInt()
        val hi = (minOf(end, base + size) - base).toInt()
        return if (lo < hi) samples.copyOfRange(lo, hi) else FloatArray(0)
    }

    /** Let go of everything before stream index `index`. */
    @Synchronized fun drop(before: Long) {
        val n = (before - base).coerceIn(0, size.toLong()).toInt()
        if (n == 0) return
        System.arraycopy(samples, n, samples, 0, size - n)
        size -= n
        base += n
    }
}

/** Where the speech comes from. */
interface AudioSource {
    val buffer: SampleBuffer
    fun start()
    fun stop()
    /** A recording that has played to its end; a microphone never is. */
    val finished: Boolean
    /** Why the source stopped delivering audio, if it did. */
    val failure: String? get() = null
}

/** A recording played in at the pace it was spoken: the live loop, with the same contention, for measuring without a microphone. */
class Recording(private val samples: FloatArray) : AudioSource {
    override val buffer = SampleBuffer()
    @Volatile override var finished = false; private set
    @Volatile private var running = false
    private var worker: Thread? = null

    override fun start() {
        running = true
        worker = thread(name = "recording") {
            val started = SystemClock.elapsedRealtimeNanos()
            var at = 0
            while (at < samples.size && running) {
                val due = ((SystemClock.elapsedRealtimeNanos() - started) / 1e9 * 16_000).toInt()
                if (due > at) {
                    val end = minOf(due, samples.size)
                    buffer.append(samples.copyOfRange(at, end))
                    at = end
                }
                Thread.sleep(20)
            }
            finished = true
        }
    }

    override fun stop() { running = false }
}

class AudioFailure(message: String) : Exception(message)

/**
 * The microphone at 16 kHz mono, as speech recognition wants it. The
 * recognition source: no automatic gain, which pumps the level between words.
 * The caller holds the RECORD_AUDIO permission.
 */
class Microphone : AudioSource {
    override val buffer = SampleBuffer()
    override val finished get() = false
    @Volatile private var running = false
    private var record: AudioRecord? = null
    private var worker: Thread? = null

    @SuppressLint("MissingPermission")
    override fun start() {
        val minimum = AudioRecord.getMinBufferSize(16_000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val record = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16_000, AudioFormat.CHANNEL_IN_MONO,
                                 AudioFormat.ENCODING_PCM_FLOAT, maxOf(minimum, 16_000 * 4 / 5))
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw AudioFailure("The microphone isn't delivering audio. Allow Interpreter to use it in Settings → Apps → Interpreter → Permissions.")
        }
        record.startRecording()
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            throw AudioFailure("The microphone is in use by another app, or a call. Try again when it's free.")
        }
        this.record = record
        running = true
        worker = thread(name = "microphone", priority = Thread.MAX_PRIORITY) {
            val block = FloatArray(1_600)  // 100 ms
            while (running) {
                val n = record.read(block, 0, block.size, AudioRecord.READ_BLOCKING)
                if (n > 0) buffer.append(block, n)
                else if (n < 0) {
                    if (running) failure = "The microphone stopped delivering audio (error $n). Press Live to try again."
                    break
                }
            }
        }
    }

    @Volatile override var failure: String? = null; private set

    override fun stop() {
        running = false
        record?.let { runCatching { it.stop() }; worker?.join(500); it.release() }
        record = null
    }
}

/**
 * Plays clips back to back and knows how far behind it is. With `audible`
 * false it only keeps the schedule, for a listen-back without speakers.
 */
class Speaker(val sampleRate: Int, private val audible: Boolean, private val clock: SessionClock) {
    private val clips = LinkedBlockingQueue<FloatArray>()
    private var end = 0.0  // session time the last scheduled clip finishes
    @Volatile private var stopped = false
    private var track: AudioTrack? = null
    private var worker: Thread? = null
    /** Every clip and the session second it starts, for the listen-back of a recording. */
    val placed = mutableListOf<Pair<Double, FloatArray>>()

    fun start() {
        if (!audible) return
        val minimum = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(sampleRate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(minimum).build()
        track.play()
        this.track = track
        worker = thread(name = "speaker") {
            while (!stopped) {
                val clip = try { clips.take() } catch (_: InterruptedException) { break }
                var at = 0
                while (at < clip.size && !stopped) {
                    val n = track.write(clip, at, clip.size - at, AudioTrack.WRITE_BLOCKING)
                    if (n <= 0) break
                    at += n
                }
            }
        }
    }

    /** How loud the interpreter is, from 0 to 1; takes effect at once. */
    var volume = 1f
        set(value) { field = value.coerceIn(0f, 1f); track?.setVolume(field) }

    /** Seconds of speech still waiting to be heard. */
    val backlog: Double @Synchronized get() = maxOf(0.0, end - clock.now())

    /** Queue a clip; returns the session time it starts playing. */
    @Synchronized fun play(samples: FloatArray): Double {
        val now = clock.now()
        if (samples.isEmpty() || stopped) return now
        val start = maxOf(now, end)
        end = start + samples.size.toDouble() / sampleRate
        // Only recording runs need a listen-back; live playback lets old audio go.
        if (audible) clips.put(samples) else placed += start to samples
        return start
    }

    fun stop() {
        synchronized(this) { stopped = true; end = clock.now() }
        clips.clear()
        // Silence at once, then stop, which returns a write blocked on a full
        // buffer; the writer is gone before the track is let go.
        track?.let { runCatching { it.pause(); it.flush(); it.stop() } }
        worker?.interrupt()
        worker?.join(500)
        track?.release()
        track = null
    }
}
