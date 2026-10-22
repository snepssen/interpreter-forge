package com.snepssen.hearing

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import com.snepssen.ort.Ort
import java.io.File
import java.nio.FloatBuffer
import java.nio.LongBuffer

/**
 * Silero VAD v5 on 32 ms frames, with hysteresis on its speech probability:
 * the iPhone app's SileroVAD, line for line. Each frame goes in with the last
 * 64 samples of the one before, which the v5 graph expects.
 */
class SileroVad(model: File, private val on: Float = 0.5f, private val off: Float = 0.35f) : AutoCloseable {
    private val env = Ort.env
    private val session = env.createSession(model.absolutePath, OrtSession.SessionOptions().apply { setIntraOpNumThreads(1) })
    private var state = FloatArray(2 * 1 * 128)
    private var previous = FloatArray(CONTEXT)
    var speaking = false; private set
    /** Stream time of the last frame heard as speech. */
    var lastSpeech = -1e9; private set

    fun reset() { state = FloatArray(256); previous = FloatArray(CONTEXT); speaking = false; lastSpeech = -1e9 }

    /** Feed one frame of [FRAME] samples ending at stream time `t`; returns whether it is speech. */
    fun push(frame: FloatArray, t: Double): Boolean {
        val input = previous + frame
        val inputs = mapOf(
            "input" to OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, input.size.toLong())),
            "state" to OnnxTensor.createTensor(env, FloatBuffer.wrap(state), longArrayOf(2, 1, 128)),
            "sr" to OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(16_000)), longArrayOf()),
        )
        val p = try {
            session.run(inputs, setOf("output", "stateN")).use { out ->
                state = floats(out.get("stateN").get() as OnnxTensor)
                floats(out.get("output").get() as OnnxTensor).firstOrNull() ?: 0f
            }
        } finally { inputs.values.forEach { it.close() } }
        previous = input.copyOfRange(input.size - CONTEXT, input.size)
        speaking = p >= on || (speaking && p >= off)
        if (speaking) lastSpeech = t
        return speaking
    }

    fun silence(now: Double) = if (speaking) 0.0 else maxOf(0.0, now - lastSpeech)

    private fun floats(t: OnnxTensor) = t.floatBuffer.let { b -> FloatArray(b.remaining()).also { b.get(it) } }

    override fun close() = session.close()

    companion object { const val FRAME = 512; const val CONTEXT = 64 }
}
